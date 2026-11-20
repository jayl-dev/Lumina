/**
 * @file src/platform/macos/esp_gamepad.m
 * @brief ESP32-S3 USB HID gamepad bridge over CDC serial.
 *
 * Wire protocol (both directions):
 *   0xA5 0x5A <type> <len> <payload[len]> <crc8>
 *   crc8 is CRC-8/SMBUS (poly 0x07, init 0x00) over <type> <len> <payload>.
 *
 * Host -> board:
 *   0x01 PING    len 0
 *   0x02 REPORT  len 14: <pad> <HIDGamepadReport without reportId (13 bytes)>
 * Board -> host:
 *   0x81 PONG    len 2: <protocol version> <pad count>
 *   0x84 RUMBLE  len 5: <pad> <low-frequency u16 LE> <high-frequency u16 LE>
 */
#import "esp_gamepad.h"
#import "hid_gamepad.h"

#import <IOKit/IOKitLib.h>
#import <IOKit/serial/IOSerialKeys.h>
#import <IOKit/usb/USBSpec.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

#define ESP_PROTOCOL_VERSION 1

#define FRAME_SYNC0 0xA5
#define FRAME_SYNC1 0x5A

#define MSG_PING   0x01
#define MSG_REPORT 0x02
#define MSG_PONG   0x81
#define MSG_RUMBLE 0x84

#define READER_POLL_MS 100

#define PING_TIMEOUT_MS 500

_Static_assert(sizeof(HIDGamepadReport) == 14, "HIDGamepadReport layout changed; update the ESP firmware");

static uint8_t crc8(const uint8_t *data, size_t len) {
    uint8_t crc = 0;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++) {
            crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x07) : (uint8_t)(crc << 1);
        }
    }
    return crc;
}

static BOOL hasSerialPrefix(io_service_t service, NSString *prefix) {
    CFTypeRef value = IORegistryEntrySearchCFProperty(
        service, kIOServicePlane, CFSTR(kUSBSerialNumberString), kCFAllocatorDefault,
        kIORegistryIterateRecursively | kIORegistryIterateParents);
    BOOL result = NO;
    if (value) {
        if (CFGetTypeID(value) == CFStringGetTypeID()) {
            result = [(__bridge NSString *)value hasPrefix:prefix];
        }
        CFRelease(value);
    }
    return result;
}

/**
 * Returns callout paths (/dev/cu.*) of serial ports on a USB device whose serial
 * number carries the firmware's prefix.
 */
static NSArray<NSString *> *findCandidatePorts(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];

    CFMutableDictionaryRef match = IOServiceMatching(kIOSerialBSDServiceValue);
    CFDictionarySetValue(match, CFSTR(kIOSerialBSDTypeKey), CFSTR(kIOSerialBSDAllTypes));

    io_iterator_t iter = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS) {
        return paths;
    }

    io_service_t service;
    while ((service = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        if (hasSerialPrefix(service, ESP_GAMEPAD_SERIAL_PREFIX)) {
            CFTypeRef path = IORegistryEntryCreateCFProperty(service, CFSTR(kIOCalloutDeviceKey), kCFAllocatorDefault, 0);
            if (path) {
                [paths addObject:[NSString stringWithString:(__bridge NSString *)path]];
                CFRelease(path);
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);

    return paths;
}

@implementation ESPGamepadLink {
    int _fd;
    pthread_t _reader;
    BOOL _readerStarted;
    volatile BOOL _stopReading;
    ESPRumbleHandler _rumbleHandler;
}

static void *readerMain(void *arg) {
    @autoreleasepool {
        [(ESPGamepadLink *)arg readLoop];
    }
    return NULL;
}

+ (instancetype)open {
    for (NSString *path in findCandidatePorts()) {
        ESPGamepadLink *link = [[ESPGamepadLink alloc] initWithPath:path];
        if (link) {
            return [link autorelease];
        }
    }
    return nil;
}

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (!self) {
        return nil;
    }
    _fd = -1;
    _devicePath = [path copy];

    int fd = open([path fileSystemRepresentation], O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) {
        NSLog(@"[ESPGamepad] Failed to open %@: %s", path, strerror(errno));
        [self release];
        return nil;
    }

    // Exclusive access so nothing else writes into our frame stream
    ioctl(fd, TIOCEXCL);

    struct termios tio;
    tcgetattr(fd, &tio);
    cfmakeraw(&tio);
    // CDC ignores baud, but avoid 1200 which triggers the ESP32 bootloader reset
    cfsetspeed(&tio, B115200);
    tio.c_cflag |= (CLOCAL | CREAD);
    tcsetattr(fd, TCSANOW, &tio);
    tcflush(fd, TCIOFLUSH);

    _fd = fd;

    if (![self handshake]) {
        NSLog(@"[ESPGamepad] %@ did not answer ping, ignoring", path);
        [self close];
        [self release];
        return nil;
    }

    // Writes are tiny; blocking keeps every state frame instead of dropping on EAGAIN
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);

    _isConnected = YES;
    NSLog(@"[ESPGamepad] Connected to %@ (%d pad(s))", path, _padCount);
    return self;
}

- (void)dealloc {
    [self close];
    [_rumbleHandler release];
    [_devicePath release];
    [super dealloc];
}

- (void)startReadingWithRumbleHandler:(ESPRumbleHandler)handler {
    if (_readerStarted || _fd < 0) {
        return;
    }
    _rumbleHandler = [handler copy];
    _stopReading = NO;
    _readerStarted = pthread_create(&_reader, NULL, readerMain, self) == 0;
}

/**
 * Reader thread: polls with a timeout so close() can stop it; owns no state the writer uses.
 * Ends on its own when the board goes away (the next write then closes the link).
 */
- (void)readLoop {
    uint8_t buf[512];
    size_t have = 0;
    int fd = _fd;
    while (!_stopReading) {
        struct pollfd pfd = {.fd = fd, .events = POLLIN};
        int r = poll(&pfd, 1, READER_POLL_MS);
        if (r < 0 && errno != EINTR) {
            break;
        }
        if (r <= 0) {
            continue;
        }
        if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
            break;
        }
        ssize_t n = read(fd, buf + have, sizeof(buf) - have);
        if (n <= 0) {
            if (n < 0 && (errno == EINTR || errno == EAGAIN)) {
                continue;
            }
            break;
        }
        have = [self consumeFrames:buf length:have + (size_t)n capacity:sizeof(buf)];
    }
}

/**
 * Handles every complete frame in buf and moves any partial frame to the front.
 * Returns the number of bytes kept.
 */
- (size_t)consumeFrames:(uint8_t *)buf length:(size_t)have capacity:(size_t)capacity {
    size_t i = 0;
    while (i + 5 <= have) {
        if (buf[i] != FRAME_SYNC0 || buf[i + 1] != FRAME_SYNC1) {
            i++;
            continue;
        }
        uint8_t len = buf[i + 3];
        if (i + 5 + len > have) {
            break;  // wait for the rest
        }
        if (crc8(&buf[i + 2], 2 + len) == buf[i + 4 + len]) {
            [self handleFrame:buf[i + 2] payload:&buf[i + 4] length:len];
            i += 5 + len;
        } else {
            i++;
        }
    }
    size_t kept = have - i;
    if (kept == capacity) {
        kept = 0;  // no frame fits: drop the garbage
    }
    memmove(buf, buf + have - kept, kept);
    return kept;
}

- (void)handleFrame:(uint8_t)type payload:(const uint8_t *)p length:(uint8_t)len {
    if (type == MSG_RUMBLE && len == 5 && _rumbleHandler) {
        uint16_t low = (uint16_t)(p[1] | (p[2] << 8));
        uint16_t high = (uint16_t)(p[3] | (p[4] << 8));
        _rumbleHandler(p[0], low, high);
    }
}

- (BOOL)writeFrame:(uint8_t)type payload:(const uint8_t *)payload length:(uint8_t)len {
    if (_fd < 0) {
        return NO;
    }

    uint8_t frame[4 + 255 + 1];
    frame[0] = FRAME_SYNC0;
    frame[1] = FRAME_SYNC1;
    frame[2] = type;
    frame[3] = len;
    if (len) {
        memcpy(&frame[4], payload, len);
    }
    frame[4 + len] = crc8(&frame[2], 2 + len);

    size_t total = 5 + len;
    size_t written = 0;
    while (written < total) {
        ssize_t n = write(_fd, frame + written, total - written);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN) {
                continue;
            }
            NSLog(@"[ESPGamepad] Write to %@ failed: %s, closing link", _devicePath, strerror(errno));
            [self close];
            return NO;
        }
        written += (size_t)n;
    }
    return YES;
}

/**
 * Sends PING and waits for a valid PONG. Ignores any unrelated bytes (e.g. boot logs).
 */
- (BOOL)handshake {
    if (![self writeFrame:MSG_PING payload:NULL length:0]) {
        return NO;
    }

    uint8_t buf[256];
    size_t have = 0;
    uint64_t deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC) + (uint64_t)PING_TIMEOUT_MS * NSEC_PER_MSEC;

    for (;;) {
        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        if (now >= deadline) {
            return NO;
        }

        struct pollfd pfd = {.fd = _fd, .events = POLLIN};
        int remaining_ms = (int)((deadline - now) / NSEC_PER_MSEC) + 1;
        if (poll(&pfd, 1, remaining_ms) <= 0) {
            continue;
        }

        ssize_t n = read(_fd, buf + have, sizeof(buf) - have);
        if (n <= 0) {
            continue;
        }
        have += (size_t)n;

        // Scan for a PONG frame: A5 5A 81 02 <ver> <pads> <crc>
        for (size_t i = 0; i + 7 <= have; i++) {
            if (buf[i] == FRAME_SYNC0 && buf[i + 1] == FRAME_SYNC1 &&
                buf[i + 2] == MSG_PONG && buf[i + 3] == 2 &&
                crc8(&buf[i + 2], 4) == buf[i + 6]) {
                uint8_t version = buf[i + 4];
                if (version != ESP_PROTOCOL_VERSION) {
                    NSLog(@"[ESPGamepad] %@ speaks protocol v%d, expected v%d; reflash the firmware",
                          _devicePath, version, ESP_PROTOCOL_VERSION);
                    return NO;
                }
                _padCount = buf[i + 5];
                return _padCount > 0;
            }
        }

        if (have == sizeof(buf)) {
            // Keep the tail in case a frame straddles the boundary
            memmove(buf, buf + have - 6, 6);
            have = 6;
        }
    }
}

- (BOOL)sendPad:(int)pad
        buttons:(uint32_t)buttons
     leftStickX:(int16_t)lsX
     leftStickY:(int16_t)lsY
    rightStickX:(int16_t)rsX
    rightStickY:(int16_t)rsY
    leftTrigger:(uint8_t)lt
   rightTrigger:(uint8_t)rt {

    if (!_isConnected || pad < 0 || pad >= _padCount) {
        return NO;
    }

    HIDGamepadReport report = HIDGamepadMakeReport(buttons, lsX, lsY, rsX, rsY, lt, rt);

    uint8_t payload[1 + sizeof(report) - 1];
    payload[0] = (uint8_t)pad;
    memcpy(&payload[1], (const uint8_t *)&report + 1, sizeof(report) - 1);

    return [self writeFrame:MSG_REPORT payload:payload length:sizeof(payload)];
}

- (void)sendNeutralForPad:(int)pad {
    [self sendPad:pad buttons:0 leftStickX:0 leftStickY:0 rightStickX:0 rightStickY:0 leftTrigger:0 rightTrigger:0];
}

- (void)close {
    _isConnected = NO;
    // Stop the reader before closing its descriptor; it notices within READER_POLL_MS
    if (_readerStarted && !pthread_equal(pthread_self(), _reader)) {
        _stopReading = YES;
        pthread_join(_reader, NULL);
        _readerStarted = NO;
    }
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
    }
}

@end
