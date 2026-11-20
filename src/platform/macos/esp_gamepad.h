/**
 * @file src/platform/macos/esp_gamepad.h
 * @brief Hardware gamepad via an ESP32-S3 acting as a USB HID controller.
 * @details The ESP32-S3 enumerates as a composite USB device: an HID gamepad
 *          plus a CDC serial port. Lumina streams gamepad state over the serial
 *          port (hid_gamepad.m report layout) and the board translates it into
 *          the controller it emulates (generic, DualShock 4 or Switch Pro), so
 *          macOS sees a real USB controller.
 *          No entitlements or SIP changes are required.
 *          Firmware lives in the separate lumina-gamepad-bridge project.
 */
#pragma once

#import <Foundation/Foundation.h>

// The board's USB VID/PID depend on the emulated controller, but its USB serial number
// always starts with this prefix (must match lumina-gamepad-bridge/src/main.cpp).
#define ESP_GAMEPAD_SERIAL_PREFIX @"LUMINA-"

/**
 * Serial link to the ESP32 board. One link drives every pad the board exposes.
 */
@interface ESPGamepadLink : NSObject

@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly) int padCount;        // HID gamepads exposed by the board
@property (nonatomic, readonly, copy) NSString *devicePath;

/**
 * Finds the board by its USB serial number prefix, opens its serial port and verifies the
 * protocol with a ping. Returns nil if no board is attached or it does not answer.
 */
+ (instancetype)open;

/**
 * Sends a gamepad state for the given pad on the board.
 * On a write failure (e.g. board unplugged) the link closes itself.
 * @return YES if the frame was written.
 */
- (BOOL)sendPad:(int)pad
        buttons:(uint32_t)buttons
     leftStickX:(int16_t)lsX
     leftStickY:(int16_t)lsY
    rightStickX:(int16_t)rsX
    rightStickY:(int16_t)rsY
    leftTrigger:(uint8_t)lt
   rightTrigger:(uint8_t)rt;

/**
 * Releases all inputs on the given pad.
 */
- (void)sendNeutralForPad:(int)pad;

- (void)close;

@end
