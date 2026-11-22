/**
 * @file src/platform/macos/display.mm
 * @brief Definitions for display capture on macOS.
 */

// standard includes
#include <charconv>
#include <optional>
#include <string_view>

// local includes
#include "src/config.h"
#include "src/display_device.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/av_img_t.h"
#include "src/platform/macos/av_video.h"
#include "src/platform/macos/misc.h"
#import "src/platform/macos/sc_capture.h"
#include "src/platform/macos/vt_encoder.h"

// Avoid conflict between AVFoundation and libavutil both defining AVMediaType
#define AVMediaType AVMediaType_FFmpeg
#include "src/video.h"
#undef AVMediaType

namespace fs = std::filesystem;

namespace platf {
  using namespace std::literals;

  namespace {
    std::optional<CGDirectDisplayID> parse_display_id(std::string_view display_name) {
      if (display_name.empty()) {
        return std::nullopt;
      }

      CGDirectDisplayID display_id {};
      const auto *const begin = display_name.data();
      const auto *const end = begin + display_name.size();
      const auto [ptr, ec] = std::from_chars(begin, end, display_id);
      if (ec != std::errc {} || ptr != end) {
        return std::nullopt;
      }

      return display_id;
    }
  }  // namespace

  /**
   * @brief Process a CMSampleBuffer frame into an img_t for the encoder pipeline.
   * Shared between AVFoundation and ScreenCaptureKit capture backends.
   */
  static bool process_frame(CMSampleBufferRef sampleBuffer, img_t *img, bool frame_repeated = false) {
    // Check for valid pixel data before processing (SCK can deliver status frames without image content)
    CVPixelBufferRef pixBuf = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixBuf) {
      return false;
    }

    auto new_sample_buffer = std::make_shared<av_sample_buf_t>(sampleBuffer);
    auto new_pixel_buffer = std::make_shared<av_pixel_buf_t>(new_sample_buffer->buf);

    auto av_img = (av_img_t *) img;

    auto old_data_retainer = std::make_shared<temp_retain_av_img_t>(
      av_img->sample_buffer,
      av_img->pixel_buffer,
      img->data
    );

    av_img->sample_buffer = new_sample_buffer;
    av_img->pixel_buffer = new_pixel_buffer;
    img->data = new_pixel_buffer->data();

    img->width = (int) CVPixelBufferGetWidth(new_pixel_buffer->buf);
    img->height = (int) CVPixelBufferGetHeight(new_pixel_buffer->buf);
    img->row_pitch = (int) CVPixelBufferGetBytesPerRow(new_pixel_buffer->buf);
    img->pixel_pitch = img->row_pitch / img->width;
    img->frame_timestamp = std::chrono::steady_clock::now();
    img->frame_repeated = frame_repeated;

    old_data_retainer = nullptr;
    return true;
  }

  // ── AVFoundation capture backend (AVCaptureScreenInput) ──────────────

  struct av_display_t: public display_t {
    AVVideo *av_capture {};
    CGDirectDisplayID display_id {};

    ~av_display_t() override {
      [av_capture release];
    }

    capture_e capture(const push_captured_image_cb_t &push_captured_image_cb, const pull_free_image_cb_t &pull_free_image_cb, bool *cursor) override {
      auto signal = [av_capture capture:^(CMSampleBufferRef sampleBuffer) {
        std::shared_ptr<img_t> img_out;
        if (!pull_free_image_cb(img_out)) {
          return false;
        }
        process_frame(sampleBuffer, img_out.get());
        if (!push_captured_image_cb(std::move(img_out), true)) {
          return false;
        }
        return true;
      }];

      // Poll with timeout instead of waiting forever, so the capture thread
      // can respond to session shutdown and not deadlock on teardown.
      while (dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC)) != 0) {
        std::shared_ptr<img_t> probe_img;
        if (!pull_free_image_cb(probe_img)) {
          // Session is shutting down. Signal the semaphore so we exit the wait.
          // Don't call stopCapture here — the callback will detect shutdown on its
          // next invocation and do a clean teardown. Force-stopping AVFoundation
          // corrupts capture state for this display, causing black frames on reconnect.
          dispatch_semaphore_signal(signal);
          break;
        }
      }
      return capture_e::ok;
    }

    std::shared_ptr<img_t> alloc_img() override {
      return std::make_shared<av_img_t>();
    }

    std::unique_ptr<avcodec_encode_device_t> make_avcodec_encode_device(pix_fmt_e pix_fmt) override {
      if (pix_fmt == pix_fmt_e::yuv420p) {
        av_capture.pixelFormat = kCVPixelFormatType_32BGRA;
        return std::make_unique<avcodec_encode_device_t>();
      } else {
        BOOST_LOG(error) << "Unsupported Pixel Format."sv;
        return nullptr;
      }
    }

    int dummy_img(img_t *img) override {
      if (!platf::is_screen_capture_allowed()) {
        return 1;
      }

      // Create a synthetic dummy frame to avoid starting a capture session.
      // Starting and stopping AVFoundation capture for dummy_img can cause
      // timeouts on virtual displays and interfere with the main capture.
      int w = av_capture.frameWidth;
      int h = av_capture.frameHeight;

      CVPixelBufferRef pixelBuffer = NULL;
      NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
      };
      CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault, w, h,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &pixelBuffer);

      if (status != kCVReturnSuccess || !pixelBuffer) {
        BOOST_LOG(error) << "AVFoundation dummy_img: failed to create pixel buffer"sv;
        return 1;
      }

      CVPixelBufferLockBaseAddress(pixelBuffer, 0);
      void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
      memset(base, 0, CVPixelBufferGetBytesPerRow(pixelBuffer) * h);
      CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

      auto av_img = (av_img_t *)img;
      CMVideoFormatDescriptionRef formatDesc = NULL;
      CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);

      CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
      CMSampleBufferRef sampleBuffer = NULL;
      CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, YES, NULL, NULL, formatDesc, &timing, &sampleBuffer);

      if (formatDesc) CFRelease(formatDesc);

      if (sampleBuffer) {
        auto new_sample = std::make_shared<av_sample_buf_t>(sampleBuffer);
        auto new_pixel = std::make_shared<av_pixel_buf_t>(new_sample->buf);
        av_img->sample_buffer = new_sample;
        av_img->pixel_buffer = new_pixel;
        img->data = new_pixel->data();
        CFRelease(sampleBuffer);
      }

      CVPixelBufferRelease(pixelBuffer);

      img->width = w;
      img->height = h;
      img->row_pitch = w * 4;
      img->pixel_pitch = 4;
      return 0;
    }

    std::unique_ptr<vt_encode_device_t> make_vt_encode_device(pix_fmt_e pix_fmt) override {
      auto *capture = av_capture;
      return vt::make_encode_device(
        pix_fmt,
        [capture](int width, int height) {
          [capture setFrameWidth:width frameHeight:height];
        },
        [capture](int pixel_format) {
          capture.pixelFormat = pixel_format;
        }
      );
    }
  };

  // ── ScreenCaptureKit capture backend (macOS 12.3+) ──────────────────

  struct sc_display_t: public display_t {
    SCCapture *sc_capture {};
    CGDirectDisplayID display_id {};

    ~sc_display_t() override {
      [sc_capture stopCapture];
      [sc_capture release];
    }

    capture_e capture(const push_captured_image_cb_t &push_captured_image_cb, const pull_free_image_cb_t &pull_free_image_cb, bool *cursor) override {
      auto signal = [sc_capture captureVideo:^(CMSampleBufferRef sampleBuffer, BOOL frameRepeated) {
        std::shared_ptr<img_t> img_out;
        if (!pull_free_image_cb(img_out)) {
          return false;
        }
        if (!process_frame(sampleBuffer, img_out.get(), frameRepeated)) {
          return true;  // skip this frame but continue capturing
        }
        if (!push_captured_image_cb(std::move(img_out), true)) {
          return false;
        }
        return true;
      } audioCallback:nil];

      if (!signal) {
        BOOST_LOG(error) << "SCCapture failed to start video capture"sv;
        return capture_e::error;
      }

      // Poll with timeout instead of waiting forever, so the capture thread
      // can respond to session shutdown and not deadlock on teardown.
      while (dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC)) != 0) {
        // Check if session is ending — pull_free_image_cb returns false when
        // the session is shutting down (capture_ctx_queue->running() == false).
        // This is needed because SCCapture may not deliver frames on an idle
        // display, so the video callback never gets a chance to detect shutdown.
        std::shared_ptr<img_t> probe_img;
        if (!pull_free_image_cb(probe_img)) {
          [sc_capture stopCapture];
          break;
        }
      }
      return capture_e::ok;
    }

    std::shared_ptr<img_t> alloc_img() override {
      return std::make_shared<av_img_t>();
    }

    std::unique_ptr<avcodec_encode_device_t> make_avcodec_encode_device(pix_fmt_e pix_fmt) override {
      if (pix_fmt == pix_fmt_e::yuv420p) {
        sc_capture.pixelFormat = kCVPixelFormatType_32BGRA;
        return std::make_unique<avcodec_encode_device_t>();
      } else {
        BOOST_LOG(error) << "Unsupported Pixel Format."sv;
        return nullptr;
      }
    }

    int dummy_img(img_t *img) override {
      if (!platf::is_screen_capture_allowed()) {
        return 1;
      }

      // Create a synthetic dummy frame instead of starting a separate capture.
      // Starting and stopping a capture just for dummy_img causes SCK to
      // not deliver frames to the subsequent main capture stream.
      int w = sc_capture.frameWidth;
      int h = sc_capture.frameHeight;

      CVPixelBufferRef pixelBuffer = NULL;
      NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
      };
      CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault, w, h,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &pixelBuffer);

      if (status != kCVReturnSuccess || !pixelBuffer) {
        BOOST_LOG(error) << "SCCapture dummy_img: failed to create pixel buffer"sv;
        return 1;
      }

      // Fill with black
      CVPixelBufferLockBaseAddress(pixelBuffer, 0);
      void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
      memset(base, 0, CVPixelBufferGetBytesPerRow(pixelBuffer) * h);
      CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

      auto av_img = (av_img_t *)img;
      // Wrap in a CMSampleBuffer for the av_img pipeline
      CMVideoFormatDescriptionRef formatDesc = NULL;
      CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);

      CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
      CMSampleBufferRef sampleBuffer = NULL;
      CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, YES, NULL, NULL, formatDesc, &timing, &sampleBuffer);

      if (formatDesc) CFRelease(formatDesc);

      if (sampleBuffer) {
        auto new_sample = std::make_shared<av_sample_buf_t>(sampleBuffer);
        auto new_pixel = std::make_shared<av_pixel_buf_t>(new_sample->buf);
        av_img->sample_buffer = new_sample;
        av_img->pixel_buffer = new_pixel;
        img->data = new_pixel->data();
        CFRelease(sampleBuffer);
      }

      CVPixelBufferRelease(pixelBuffer);

      img->width = w;
      img->height = h;
      img->row_pitch = w * 4;
      img->pixel_pitch = 4;
      return 0;
    }

    std::unique_ptr<vt_encode_device_t> make_vt_encode_device(pix_fmt_e pix_fmt) override {
      auto *capture = sc_capture;
      return vt::make_encode_device(
        pix_fmt,
        [capture](int width, int height) {
          [capture setFrameWidth:width frameHeight:height];
        },
        [capture](int pixel_format) {
          capture.pixelFormat = pixel_format;
        }
      );
    }
  };

  // ── Display factory ─────────────────────────────────────────────────

  std::shared_ptr<display_t> display(platf::mem_type_e hwdevice_type, const std::string &display_name, const video::config_t &config) {
    if (hwdevice_type != platf::mem_type_e::system && hwdevice_type != platf::mem_type_e::videotoolbox) {
      BOOST_LOG(error) << "Could not initialize display with the given hw device type."sv;
      return nullptr;
    }

    CGDirectDisplayID selected_display_id;

    // Check if a virtual display is active — use it preferentially.
    // While the virtual display is mirroring another display it cannot be
    // captured directly, so this resolves to the mirror master instead.
    auto vd_id = platf::virtual_display_get_target_id();
    if (vd_id != 0) {
      auto created_id = platf::virtual_display_get_id();
      if (vd_id != created_id) {
        BOOST_LOG(info) << "Virtual display "sv << created_id << " is mirroring display "sv << vd_id
                        << "; capturing the mirror master instead"sv;
      } else {
        BOOST_LOG(info) << "Using virtual display (id: "sv << vd_id << ") for capture"sv;
      }
      selected_display_id = (CGDirectDisplayID) vd_id;
    } else {
      // Default to main display
      selected_display_id = CGMainDisplayID();

      if (const auto configured_display_id = parse_display_id(display_name)) {
        selected_display_id = *configured_display_id;
      } else if (!display_name.empty()) {
        BOOST_LOG(warning) << "Configured display ["sv << display_name
                           << "] is not a valid macOS capture display id. Falling back to main display ["sv
                           << selected_display_id << "]."sv;
      }

      // Prefer Sunshine's libdisplaydevice enumeration when the active
      // dependency supports macOS, with the native list as a compatibility fallback.
      BOOST_LOG(debug) << "Detecting displays"sv;
      const auto devices = display_device::enumerate_devices();
      if (!devices.empty()) {
        for (const auto &device : devices) {
          if (!device.m_display_name.empty()) {
            BOOST_LOG(debug) << "Detected display: "sv << device.m_friendly_name
                             << " (id: "sv << device.m_display_name << ") connected: true"sv;
          }
        }
      } else {
        for (NSDictionary *item in [AVVideo displayNames]) {
          NSNumber *display_id = item[@"id"];
          NSString *name = item[@"displayName"];
          BOOST_LOG(debug) << "Detected display: "sv << name.UTF8String << " (id: "sv << [NSString stringWithFormat:@"%@", display_id].UTF8String << ") connected: true"sv;
        }
      }
    }
    BOOST_LOG(info) << "Configuring selected display ("sv << selected_display_id << ") to stream"sv;

    // ScreenCaptureKit capture backend — handles virtual display reconnection
    // reliably. AVFoundation's AVCaptureScreenInput stops delivering frames
    // when a virtual display is destroyed and recreated between sessions.
    if (@available(macOS 12.3, *)) {
      if ([SCCapture isAvailable]) {
        auto disp = std::make_shared<sc_display_t>();
        disp->display_id = selected_display_id;
        disp->sc_capture = [[SCCapture alloc] initWithDisplay:selected_display_id frameRate:config.framerate captureAudio:NO];

        if (!disp->sc_capture) {
          BOOST_LOG(error) << "SCCapture setup failed, trying AVFoundation..."sv;
        } else {
          disp->width = disp->sc_capture.frameWidth;
          disp->height = disp->sc_capture.frameHeight;
          disp->env_width = disp->width;
          disp->env_height = disp->height;
          return disp;
        }
      }
    }

    // Fallback: AVFoundation capture backend
    auto disp = std::make_shared<av_display_t>();
    disp->display_id = selected_display_id;
    disp->av_capture = [[AVVideo alloc] initWithDisplay:selected_display_id frameRate:config.framerate];

    if (!disp->av_capture) {
      BOOST_LOG(error) << "Video setup failed."sv;
      return nullptr;
    }

    disp->width = disp->av_capture.frameWidth;
    disp->height = disp->av_capture.frameHeight;
    disp->env_width = disp->width;
    disp->env_height = disp->height;

    return disp;
  }

  std::vector<std::string> display_names(mem_type_e hwdevice_type) {
    __block std::vector<std::string> display_names;

    if (hwdevice_type != platf::mem_type_e::system && hwdevice_type != platf::mem_type_e::videotoolbox) {
      return display_names;
    }

    const auto devices = display_device::enumerate_devices();
    if (!devices.empty()) {
      display_names.reserve(devices.size());
      for (const auto &device : devices) {
        if (!device.m_display_name.empty()) {
          display_names.emplace_back(device.m_display_name);
        }
      }
      return display_names;
    }

    auto display_array = [AVVideo displayNames];

    display_names.reserve([display_array count]);
    [display_array enumerateObjectsUsingBlock:^(NSDictionary *_Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
      NSString *name = obj[@"name"];
      display_names.emplace_back(name.UTF8String);
    }];

    return display_names;
  }

  /**
   * @brief Returns if GPUs/drivers have changed since the last call to this function.
   * @return `true` if a change has occurred or if it is unknown whether a change occurred.
   */
  bool needs_encoder_reenumeration() {
    // We don't track GPU state, so we will always reenumerate. Fortunately, it is fast on macOS.
    return true;
  }
}  // namespace platf
