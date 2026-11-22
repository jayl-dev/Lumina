/**
 * @file tests/unit/platform/macos/test_vt_encode_device.mm
 * @brief Hardware tests for the pipelined VideoToolbox encode device.
 */
// Only compile these tests on macOS
#ifdef __APPLE__
  // test includes
  #include "../../../tests_common.h"

  // standard includes
  #include <atomic>
  #include <memory>

  // lib includes
  #import <CoreMedia/CoreMedia.h>
  #import <CoreVideo/CoreVideo.h>

  // local includes
  #include <src/platform/macos/av_img_t.h>
  #include <src/platform/macos/vt_encoder.h>

  // Avoid conflict between AVFoundation and libavutil both defining AVMediaType
  #define AVMediaType AVMediaType_FFmpeg
  #include <src/video.h>
  #undef AVMediaType

namespace {
  constexpr int width = 640;
  constexpr int height = 360;

  /**
   * @brief Store a new captured frame in an image slot the way the capture backends do.
   *
   * The slot replaces its sample buffer before its pixel buffer, so the encoder can end up
   * holding the last reference to a frame's buffers in either order.
   */
  void capture_into(platf::av_img_t &slot) {
    CVPixelBufferRef pixel_buffer = nullptr;
    NSDictionary *attrs = @{(NSString *) kCVPixelBufferIOSurfacePropertiesKey: @{}};
    ASSERT_EQ(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef) attrs, &pixel_buffer), kCVReturnSuccess);
    CMVideoFormatDescriptionRef format = nullptr;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixel_buffer, &format);
    CMSampleTimingInfo timing {kCMTimeInvalid, kCMTimeZero, kCMTimeInvalid};
    CMSampleBufferRef sample_buffer = nullptr;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixel_buffer, format, &timing, &sample_buffer);

    auto new_sample = std::make_shared<platf::av_sample_buf_t>(sample_buffer);
    auto new_pixel = std::make_shared<platf::av_pixel_buf_t>(new_sample->buf);
    CFRelease(sample_buffer);
    CFRelease(format);
    CFRelease(pixel_buffer);

    slot.sample_buffer = std::move(new_sample);
    slot.pixel_buffer = std::move(new_pixel);
  }
}  // namespace

/**
 * @brief Frames released by the capture side while still being encoded must stay valid until VideoToolbox is done with them.
 */
TEST(VTEncodeDevice, FramesReleasedWhileInFlightStayValid) {
  auto device = platf::vt::make_encode_device(platf::pix_fmt_e::nv12, [](int, int) {}, [](int) {});
  ASSERT_TRUE(device);

  video::config_t config {};
  config.width = width;
  config.height = height;
  config.framerate = 120;
  config.bitrate = 5000;
  config.videoFormat = 1;
  std::atomic<int> frames_out {0};
  std::atomic<int> idr_frames {0};
  if (!device->init_encoder(config, {video::colorspace_e::rec709, false, 8}, [&](platf::vt_encoded_frame &&frame) {
        ++frames_out;
        idr_frames += frame.idr;
      })) {
    GTEST_SKIP() << "No VideoToolbox hardware HEVC encoder available";
  }

  constexpr int frame_count = 240;
  platf::av_img_t slot;
  for (int i = 0; i < frame_count; ++i) {
    capture_into(slot);
    ASSERT_EQ(device->convert(slot), 0);
    ASSERT_TRUE(device->encode_frame(i, i == 0)) << "frame " << i;
    // The capture backend may drop its sample buffer while the frame is still in flight
    slot.sample_buffer.reset();
  }
  // Destroying the device flushes and invalidates the session; frames still in flight are discarded
  device.reset();

  EXPECT_GE(frames_out.load(), frame_count - 2);
  EXPECT_GE(idr_frames.load(), 1);
}
#endif
