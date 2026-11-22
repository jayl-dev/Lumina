/**
 * @file src/platform/macos/vt_encoder.mm
 * @brief Definitions for the native VideoToolbox encoder on macOS.
 *
 * Encodes captured CVPixelBuffers directly through a VTCompressionSession. Up to two frames are in
 * flight; encoded frames are delivered from the output callback as soon as they complete, in
 * submission order with exactly one packet per frame index.
 */
// standard includes
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <limits>
#include <mutex>
#include <optional>
#include <set>
#include <tuple>
#include <vector>

// platform includes
#include <CoreMedia/CoreMedia.h>
#include <VideoToolbox/VideoToolbox.h>

// local includes
#include "src/logging.h"
#include "src/platform/macos/av_img_t.h"
#include "src/platform/macos/vt_encoder.h"
#include "src/utility.h"
#include "src/video.h"

namespace {
  using namespace std::literals;
  using clock_t_ = std::chrono::steady_clock;

  // Frames VideoToolbox may hold at once. A second frame in flight lets standard rate control use
  // the encoder's parallelism when one frame takes longer than the frame interval.
  constexpr std::size_t max_frames_in_flight = 2;

  // Low-latency rate control encodes one frame at a time; when its average encode time exceeds the
  // frame interval by this factor, the session falls back to pipelined standard rate control.
  constexpr double low_latency_overrun_factor = 1.05;
  constexpr int latency_warmup_frames = 10;
  constexpr int latency_window_frames = 60;

  // Stream modes whose low-latency encode couldn't keep up, so reconnects start in standard rate control
  std::mutex standard_modes_mutex;
  std::set<std::tuple<CMVideoCodecType, int, int, int, unsigned>> standard_modes;

  std::tuple<CMVideoCodecType, int, int, int, unsigned> stream_mode(CMVideoCodecType codec, const video::config_t &config, const video::sunshine_colorspace_t &colorspace) {
    return {codec, config.width, config.height, config.framerate, colorspace.bit_depth};
  }

  /**
   * @brief Pipelined wrapper around a VTCompressionSession.
   *
   * Up to `max_frames_in_flight` frames are submitted at once. Encoded frames are converted to
   * Annex-B on the VideoToolbox output thread and handed to the sink immediately, in frame order.
   */
  class vt_compression_session_t {
  public:
    explicit vt_compression_session_t(platf::vt_packet_sink_t sink):
        sink(std::move(sink)) {
    }

    ~vt_compression_session_t() {
      if (session) {
        {
          std::lock_guard lg {mutex};
          discard = true;
        }
        VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
        // Guarantees no output callbacks after return
        VTCompressionSessionInvalidate(session);
        CFRelease(session);
      }
    }

    /**
     * @brief Create and configure the compression session.
     *
     * @param codec CoreMedia codec type to encode.
     * @param config Client stream configuration negotiated for this session.
     * @param colorspace Colorimetry information used for encoding.
     * @param low_latency Whether to request low-latency rate control.
     * @return True when the session is ready to encode.
     */
    bool init(CMVideoCodecType codec, const video::config_t &config, const video::sunshine_colorspace_t &colorspace, bool low_latency) {
      width = config.width;
      height = config.height;
      framerate = config.framerate;
      this->low_latency = low_latency;

      if (!create_session(codec, config, low_latency)) {
        return false;
      }
      BOOST_LOG(info) << "VideoToolbox session uses "sv << (low_latency ? "low-latency"sv : "standard"sv) << " rate control"sv;

      set_property(kVTCompressionPropertyKey_RealTime, config::video.vt.vt_realtime ? kCFBooleanTrue : kCFBooleanFalse, "RealTime"sv);
      set_property(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "AllowFrameReordering"sv);
      if (config::video.vt.vt_max_frame_delay >= 0) {
        set_int_property(kVTCompressionPropertyKey_MaxFrameDelayCount, config::video.vt.vt_max_frame_delay, "MaxFrameDelayCount"sv);
      }
      if (codec == kCMVideoCodecType_H264) {
        // Low-latency H.264 sessions mark pictures as long-term references by default; some
        // client hardware decoders mishandle that and freeze, so keep to short-term references.
        set_property(kVTCompressionPropertyKey_EnableLTR, kCFBooleanFalse, "EnableLTR"sv);
        if (const auto entropy_mode = platf::vt::h264_entropy_mode(config::video.vt.vt_coder)) {
          set_property(kVTCompressionPropertyKey_H264EntropyMode, entropy_mode, "H264EntropyMode"sv);
        }
      }

      CFStringRef profile;
      if (codec == kCMVideoCodecType_HEVC) {
        profile = colorspace.bit_depth == 10 ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel;
      } else {
        profile = kVTProfileLevel_H264_High_AutoLevel;
      }
      if (!set_property(kVTCompressionPropertyKey_ProfileLevel, profile, "ProfileLevel"sv) && colorspace.bit_depth == 10) {
        // 10-bit output without the Main10 profile would be broken
        return false;
      }

      // Set before the bitrate properties: rate control sizes its frame budgets from the expected rate
      const int expected_rate = platf::vt::expected_frame_rate(codec, config.width, config.height, config.framerate);
      if (expected_rate != config.framerate) {
        BOOST_LOG(info) << "VideoToolbox H.264 expected frame rate capped at "sv << expected_rate << " (level 5.2 limit for "sv
                        << config.width << 'x' << config.height << ")"sv;
      }
      set_int_property(kVTCompressionPropertyKey_ExpectedFrameRate, expected_rate, "ExpectedFrameRate"sv);

      // Honor the host-side bitrate ceiling, matching the avcodec path
      const int bitrate_kbps = config::video.max_bitrate > 0 ? std::min(config.bitrate, config::video.max_bitrate) : config.bitrate;
      BOOST_LOG(info) << "Streaming bitrate is "sv << bitrate_kbps * 1000;
      // No DataRateLimits under low-latency rate control: with a hard byte window it drops frames
      // that would exceed it (e.g. full-screen changes at 4K120). Without it, AverageBitRate still
      // steers the rate and oversized frames cost quality on later frames instead of a drop.
      set_int_property(kVTCompressionPropertyKey_AverageBitRate, bitrate_kbps * 1000, "AverageBitRate"sv);
      if (!low_latency) {
        // Standard rate control treats AverageBitRate as a long-term target, so bound each second
        // to the bitrate, matching what the avcodec path requested for these sessions.
        set_data_rate_limit(bitrate_kbps * 1000 / 8);
      }
      set_int_property(kVTCompressionPropertyKey_MaxKeyFrameInterval, std::numeric_limits<int>::max(), "MaxKeyFrameInterval"sv);
      apply_colorspace(colorspace);

      const auto prepare_status = VTCompressionSessionPrepareToEncodeFrames(session);
      if (prepare_status != noErr) {
        BOOST_LOG(warning) << "VTCompressionSessionPrepareToEncodeFrames failed: "sv << prepare_status;
      }
      return true;
    }

    /**
     * @brief Submit one frame, blocking only while the pipeline is full.
     *
     * @param pixel_buffer Captured frame to encode; retained until its output arrives.
     * @param sample_buffer Sample buffer that owns the captured frame.
     * @param frame_index Monotonic frame index assigned by the video pipeline.
     * @param force_idr Whether the frame must be encoded as an IDR frame.
     * @return False when the encoder has failed.
     */
    bool submit(std::shared_ptr<platf::av_pixel_buf_t> pixel_buffer, std::shared_ptr<platf::av_sample_buf_t> sample_buffer, uint64_t frame_index, bool force_idr) {
      if (CVPixelBufferGetWidth(pixel_buffer->buf) != (size_t) width || CVPixelBufferGetHeight(pixel_buffer->buf) != (size_t) height) {
        BOOST_LOG(error) << "VideoToolbox captured frame is "sv << CVPixelBufferGetWidth(pixel_buffer->buf) << 'x' << CVPixelBufferGetHeight(pixel_buffer->buf)
                         << " but the session expects "sv << width << 'x' << height;
        return false;
      }
      CVPixelBufferRef buf = pixel_buffer->buf;

      {
        std::unique_lock lock {mutex};
        if (!cv.wait_for(lock, 1s, [this] {
              return failed || in_flight.size() < max_frames_in_flight;
            })) {
          BOOST_LOG(error) << "VideoToolbox encode timed out"sv;
          return false;
        }
        if (failed) {
          return false;
        }
        if (need_idr) {
          force_idr = true;
          need_idr = false;
        }
        // Keep the captured buffers alive until VideoToolbox has finished reading them; the img_t
        // pool recycles images (and releases their buffers) at any time.
        in_flight.push_back({frame_index, force_idr, clock_t_::now(), std::move(sample_buffer), std::move(pixel_buffer)});
      }

      CFDictionaryRef frame_options = nullptr;
      if (force_idr) {
        CFMutableDictionaryRef options = CFDictionaryCreateMutable(kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(options, kVTEncodeFrameOptionKey_ForceKeyFrame, kCFBooleanTrue);
        frame_options = options;
      }
      const auto encode_status = VTCompressionSessionEncodeFrame(session, buf, CMTimeMake(frame_index, framerate), kCMTimeInvalid, frame_options, nullptr, nullptr);
      if (frame_options) {
        CFRelease(frame_options);
      }
      if (encode_status != noErr) {
        BOOST_LOG(error) << "VTCompressionSessionEncodeFrame failed: "sv << encode_status;
        std::lock_guard lg {mutex};
        failed = true;
        return false;
      }
      return true;
    }

    /**
     * @brief Emit every frame still in flight.
     */
    void drain() {
      VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
    }

    /**
     * @brief Report the average encode time once a full measurement window has completed.
     *
     * @return Average submit-to-output time in milliseconds, or nothing while the window fills.
     */
    std::optional<double> take_window_average_ms() {
      std::lock_guard lg {mutex};
      if (window_count < latency_window_frames) {
        return std::nullopt;
      }
      const auto average = window_sum_ms / window_count;
      window_count = 0;
      window_sum_ms = 0;
      return average;
    }

    bool is_low_latency() const {
      return low_latency;
    }

  private:
    struct in_flight_t {
      uint64_t frame_index;
      bool force_idr;
      clock_t_::time_point submitted;
      // Declared first so the pixel buffer is unlocked before the sample buffer is released
      std::shared_ptr<platf::av_sample_buf_t> sample_buffer;
      std::shared_ptr<platf::av_pixel_buf_t> pixel_buffer;
    };

    static void output_callback(void *refcon, void *, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample_buffer) {
      static_cast<vt_compression_session_t *>(refcon)->on_output(status, flags, sample_buffer);
    }

    void on_output(OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample_buffer) {
      std::unique_lock lock {mutex};
      if (in_flight.empty()) {
        BOOST_LOG(error) << "VideoToolbox delivered output with no frame in flight"sv;
        failed = true;
        cv.notify_all();
        return;
      }
      // Frame reordering is disabled, so outputs arrive in submission order
      auto frame = std::move(in_flight.front());
      in_flight.pop_front();

      auto finish = util::fail_guard([&]() {
        cv.notify_all();
      });

      if (discard || failed) {
        return;
      }
      if (status != noErr) {
        BOOST_LOG(error) << "VideoToolbox encode failed: "sv << status;
        failed = true;
        return;
      }
      if ((flags & kVTEncodeInfo_FrameDropped) || !sample_buffer) {
        // A dropped frame would leave a gap in the frame index sequence, which the
        // client treats as fatal, so the session is torn down and recreated instead.
        BOOST_LOG(error) << "VideoToolbox dropped a frame"sv;
        failed = true;
        return;
      }

      bool sync = true;
      CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample_buffer, false);
      if (attachments && CFArrayGetCount(attachments) > 0) {
        auto dict = (CFDictionaryRef) CFArrayGetValueAtIndex(attachments, 0);
        auto not_sync = (CFBooleanRef) CFDictionaryGetValue(dict, kCMSampleAttachmentKey_NotSync);
        sync = !not_sync || !CFBooleanGetValue(not_sync);
      }
      if (frame.force_idr && !sync) {
        BOOST_LOG(error) << "VideoToolbox did not honor the IDR request"sv;
        need_idr = true;
      }

      // New parameter sets on a non-IDR frame would never reach the client, which only
      // receives them prepended to IDR frames.
      CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample_buffer);
      if (!sync && last_format && format != last_format) {
        BOOST_LOG(warning) << "VideoToolbox format description changed without a keyframe, forcing IDR"sv;
        need_idr = true;
      }
      last_format = format;

      platf::vt_encoded_frame result;
      if (!platf::vt::append_annexb(sample_buffer, sync, result.data)) {
        failed = true;
        return;
      }
      result.frame_index = frame.frame_index;
      result.idr = sync;

      const double encode_ms = std::chrono::duration<double, std::milli>(clock_t_::now() - frame.submitted).count();
      if (++frames_out > latency_warmup_frames) {
        window_sum_ms += encode_ms;
        ++window_count;
      }
      frame_size_logger.collect_and_log(result.data.size() / 1000.);

      // Deliver without holding the lock so the sink never stalls submission. Outputs are
      // serialized by VideoToolbox, so frame order is preserved.
      lock.unlock();
      sink(std::move(result));
      lock.lock();
    }

    bool create_session(CMVideoCodecType codec, const video::config_t &config, bool low_latency) {
      CFMutableDictionaryRef specification = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
      // VideoToolbox's software encoder is far slower than Sunshine's own software encoder, so
      // fail without hardware and let encoder selection fall back to that instead.
      CFDictionarySetValue(specification, kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder, kCFBooleanTrue);
      if (low_latency) {
        CFDictionarySetValue(specification, kVTVideoEncoderSpecification_EnableLowLatencyRateControl, kCFBooleanTrue);
      }

      const auto status = VTCompressionSessionCreate(kCFAllocatorDefault, config.width, config.height, codec, specification, nullptr, nullptr, output_callback, this, &session);
      CFRelease(specification);
      if (status != noErr || !session) {
        BOOST_LOG(warning) << "VTCompressionSessionCreate failed (low latency: "sv << low_latency << "): "sv << status;
        session = nullptr;
        return false;
      }
      return true;
    }

    void set_data_rate_limit(std::int64_t bytes_per_second) {
      constexpr std::int64_t one_second = 1;
      CFNumberRef bytes = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &bytes_per_second);
      CFNumberRef seconds = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &one_second);
      const void *values[] = {bytes, seconds};
      CFArrayRef limits = CFArrayCreate(kCFAllocatorDefault, values, 2, &kCFTypeArrayCallBacks);
      set_property(kVTCompressionPropertyKey_DataRateLimits, limits, "DataRateLimits"sv);
      CFRelease(limits);
      CFRelease(seconds);
      CFRelease(bytes);
    }

    bool set_property(CFStringRef key, CFTypeRef value, std::string_view name) {
      const auto status = VTSessionSetProperty(session, key, value);
      if (status != noErr) {
        BOOST_LOG(warning) << "VideoToolbox rejected "sv << name << ": "sv << status;
        return false;
      }
      return true;
    }

    bool set_int_property(CFStringRef key, int value, std::string_view name) {
      CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
      const auto ok = set_property(key, number, name);
      CFRelease(number);
      return ok;
    }

    void apply_colorspace(const video::sunshine_colorspace_t &colorspace) {
      CFStringRef primaries;
      CFStringRef transfer;
      CFStringRef matrix;
      switch (colorspace.colorspace) {
        case video::colorspace_e::rec601:
          primaries = kCVImageBufferColorPrimaries_SMPTE_C;
          transfer = kCVImageBufferTransferFunction_ITU_R_709_2;
          matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4;
          break;
        case video::colorspace_e::rec709:
          primaries = kCVImageBufferColorPrimaries_ITU_R_709_2;
          transfer = kCVImageBufferTransferFunction_ITU_R_709_2;
          matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
          break;
        case video::colorspace_e::bt2020sdr:
          primaries = kCVImageBufferColorPrimaries_ITU_R_2020;
          transfer = kCVImageBufferTransferFunction_ITU_R_709_2;
          matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
          break;
        case video::colorspace_e::bt2020:
          primaries = kCVImageBufferColorPrimaries_ITU_R_2020;
          transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
          matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
          break;
      }
      set_property(kVTCompressionPropertyKey_ColorPrimaries, primaries, "ColorPrimaries"sv);
      set_property(kVTCompressionPropertyKey_TransferFunction, transfer, "TransferFunction"sv);
      set_property(kVTCompressionPropertyKey_YCbCrMatrix, matrix, "YCbCrMatrix"sv);
    }

    platf::vt_packet_sink_t sink;
    VTCompressionSessionRef session = nullptr;
    int width = 0;
    int height = 0;
    int framerate = 60;
    bool low_latency = false;

    std::mutex mutex;
    std::condition_variable cv;
    std::deque<in_flight_t> in_flight;
    bool failed = false;
    bool discard = false;
    bool need_idr = false;
    int frames_out = 0;
    int window_count = 0;
    double window_sum_ms = 0;
    logging::min_max_avg_periodic_logger<double> frame_size_logger = {debug, "VideoToolbox: encoded frame sizes in kB", ""};  ///< Periodic encoded frame size statistics.
    // Pointer identity only, never dereferenced; used to notice mid-stream parameter set changes
    CMFormatDescriptionRef last_format = nullptr;
  };

  /**
   * @brief Native VideoToolbox encode device bound to a macOS capture pipeline.
   */
  class vt_encode_device final: public platf::vt_encode_device_t {
  public:
    int init(platf::pix_fmt_e pix_fmt, platf::vt::resolution_fn_t resolution_fn, const platf::vt::pixel_format_fn_t &pixel_format_fn) {
      this->resolution_fn = std::move(resolution_fn);
      // Must happen before capture starts; the capture backend snapshots it when the stream is created
      pixel_format_fn(pix_fmt == platf::pix_fmt_e::p010 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
      return 0;
    }

    bool init_encoder(const video::config_t &client_config, const video::sunshine_colorspace_t &colorspace, platf::vt_packet_sink_t sink) override {
      if (client_config.videoFormat == 2) {
        BOOST_LOG(info) << "VideoToolbox encoder doesn't support AV1"sv;
        return false;
      }
      if (client_config.videoFormat == 0 && colorspace.bit_depth == 10) {
        BOOST_LOG(error) << "VideoToolbox encoder doesn't support 10-bit H.264"sv;
        return false;
      }

      resolution_fn(client_config.width, client_config.height);

      config = client_config;
      this->colorspace = colorspace;
      this->sink = std::move(sink);
      codec = client_config.videoFormat == 1 ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;
      frame_interval_ms = 1000.0 / std::max(1, client_config.framerate);

#if defined(__arm64__) || defined(__aarch64__)
      constexpr bool arm64 = true;
#else
      constexpr bool arm64 = false;
#endif
      bool try_low_latency = platf::vt::try_low_latency(codec, arm64);
      if (try_low_latency) {
        std::lock_guard lg {standard_modes_mutex};
        if (standard_modes.contains(stream_mode(codec, config, colorspace))) {
          BOOST_LOG(info) << "VideoToolbox low-latency rate control couldn't keep up with this stream mode before; using standard rate control"sv;
          try_low_latency = false;
        }
      }
      if (try_low_latency && create_session(true)) {
        return true;
      }
      if (try_low_latency) {
        BOOST_LOG(info) << "VideoToolbox low-latency rate control is unavailable; using standard rate control"sv;
      }
      if (!create_session(false)) {
        BOOST_LOG(error) << "VideoToolbox could not create a compression session"sv;
        return false;
      }
      return true;
    }

    int convert(platf::img_t &img) override {
      auto av_img = (platf::av_img_t *) &img;
      if (!av_img->pixel_buffer || !av_img->pixel_buffer->buf) {
        return -1;
      }

      pixel_buffer = av_img->pixel_buffer;
      sample_buffer = av_img->sample_buffer;
      return 0;
    }

    bool encode_frame(uint64_t frame_index, bool force_idr) override {
      if (!session || !pixel_buffer) {
        return false;
      }

      if (session->is_low_latency()) {
        if (const auto average_ms = session->take_window_average_ms(); average_ms && *average_ms > frame_interval_ms * low_latency_overrun_factor) {
          // Low-latency rate control can't overlap frames, so it can't reach the requested frame rate
          BOOST_LOG(info) << "VideoToolbox low-latency encode averages "sv << *average_ms << " ms against a "sv << frame_interval_ms
                          << " ms frame interval; switching to pipelined standard rate control"sv;
          {
            std::lock_guard lg {standard_modes_mutex};
            standard_modes.insert(stream_mode(codec, config, colorspace));
          }
          session->drain();
          session.reset();
          if (!create_session(false)) {
            BOOST_LOG(error) << "VideoToolbox could not create a standard rate control session"sv;
            return false;
          }
          // The new session's parameter sets only reach the client on an IDR frame
          force_idr = true;
        }
      }

      return session->submit(pixel_buffer, sample_buffer, frame_index, force_idr);
    }

  private:
    bool create_session(bool low_latency) {
      auto new_session = std::make_unique<vt_compression_session_t>(sink);
      if (!new_session->init(codec, config, colorspace, low_latency)) {
        return false;
      }
      session = std::move(new_session);
      return true;
    }

    platf::vt::resolution_fn_t resolution_fn;
    platf::vt_packet_sink_t sink;
    video::config_t config {};
    video::sunshine_colorspace_t colorspace {};
    CMVideoCodecType codec = kCMVideoCodecType_H264;
    double frame_interval_ms = 1000.0 / 60;
    std::unique_ptr<vt_compression_session_t> session;
    std::shared_ptr<platf::av_sample_buf_t> sample_buffer;
    std::shared_ptr<platf::av_pixel_buf_t> pixel_buffer;
  };
}  // namespace

namespace platf::vt {
  bool append_annexb(CMSampleBufferRef sample_buffer, bool idr, std::vector<uint8_t> &out) {
    constexpr uint8_t start_code[] = {0, 0, 0, 1};
    const auto start_size = out.size();
    auto restore_out = util::fail_guard([&]() {
      out.resize(start_size);
    });

    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample_buffer);
    if (!format) {
      BOOST_LOG(error) << "VideoToolbox sample buffer has no format description"sv;
      return false;
    }
    const bool hevc = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC;

    size_t parameter_set_count = 0;
    int nal_length_size = 4;
    {
      const uint8_t *ps = nullptr;
      size_t ps_size = 0;
      const auto status = hevc ?
                            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 0, &ps, &ps_size, &parameter_set_count, &nal_length_size) :
                            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &ps, &ps_size, &parameter_set_count, &nal_length_size);
      if (status != noErr) {
        BOOST_LOG(error) << "VideoToolbox parameter set query failed: "sv << status;
        return false;
      }
    }

    if (idr) {
      for (size_t i = 0; i < parameter_set_count; ++i) {
        const uint8_t *ps = nullptr;
        size_t ps_size = 0;
        const auto status = hevc ?
                              CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, i, &ps, &ps_size, nullptr, nullptr) :
                              CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, i, &ps, &ps_size, nullptr, nullptr);
        if (status != noErr || !ps_size) {
          BOOST_LOG(error) << "VideoToolbox parameter set "sv << i << " query failed: "sv << status;
          return false;
        }
        if (i == 0) {
          const int nal_type = hevc ? ((ps[0] >> 1) & 0x3f) : (ps[0] & 0x1f);
          const int expected = hevc ? 32 : 7;  // Moonlight requires VPS-first (HEVC) / SPS-first (H.264) IDR frames
          if (nal_type != expected) {
            BOOST_LOG(error) << "VideoToolbox emitted unexpected leading parameter set NAL type "sv << nal_type;
          }
        }
        out.insert(out.end(), std::begin(start_code), std::end(start_code));
        out.insert(out.end(), ps, ps + ps_size);
      }
    }

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample_buffer);
    if (!block) {
      BOOST_LOG(error) << "VideoToolbox sample buffer has no data buffer"sv;
      return false;
    }

    char *data = nullptr;
    size_t contiguous_length = 0;
    size_t total_length = 0;
    CMBlockBufferRef contiguous = nullptr;
    auto status = CMBlockBufferGetDataPointer(block, 0, &contiguous_length, &total_length, &data);
    if (status != kCMBlockBufferNoErr || contiguous_length < total_length) {
      if (CMBlockBufferCreateContiguous(kCFAllocatorDefault, block, nullptr, nullptr, 0, 0, 0, &contiguous) != kCMBlockBufferNoErr) {
        BOOST_LOG(error) << "VideoToolbox block buffer could not be made contiguous"sv;
        return false;
      }
      status = CMBlockBufferGetDataPointer(contiguous, 0, &contiguous_length, &total_length, &data);
      if (status != kCMBlockBufferNoErr || contiguous_length < total_length) {
        CFRelease(contiguous);
        BOOST_LOG(error) << "VideoToolbox contiguous block buffer access failed: "sv << status;
        return false;
      }
    }

    bool ok = true;
    size_t offset = 0;
    while (offset + nal_length_size <= total_length) {
      uint64_t nal_length = 0;
      for (int i = 0; i < nal_length_size; ++i) {
        nal_length = (nal_length << 8) | (uint8_t) data[offset + i];
      }
      offset += nal_length_size;
      if (!nal_length || nal_length > total_length - offset) {
        ok = false;
        break;
      }
      out.insert(out.end(), std::begin(start_code), std::end(start_code));
      out.insert(out.end(), data + offset, data + offset + nal_length);
      offset += nal_length;
    }
    if (offset != total_length) {
      ok = false;
    }
    if (!ok) {
      BOOST_LOG(error) << "VideoToolbox produced a malformed AVCC bitstream"sv;
    }
    if (contiguous) {
      CFRelease(contiguous);
    }
    if (ok) {
      restore_out.disable();
    }
    return ok;
  }

  bool try_low_latency(CMVideoCodecType codec, bool arm64) {
    return codec == kCMVideoCodecType_H264 || arm64;
  }

  CFStringRef h264_entropy_mode(int coder) {
    switch (coder) {
      case 1:
        return kVTH264EntropyMode_CABAC;
      case 2:
        return kVTH264EntropyMode_CAVLC;
      default:
        return nullptr;
    }
  }

  int expected_frame_rate(CMVideoCodecType codec, int width, int height, int framerate) {
    if (codec != kCMVideoCodecType_H264 || width <= 0 || height <= 0) {
      return framerate;
    }

    // H.264 level 5.2 MaxMBPS (macroblocks per second), Table A-1
    constexpr std::int64_t max_macroblocks_per_second = 2073600;
    const std::int64_t macroblocks_per_frame = static_cast<std::int64_t>((width + 15) / 16) * ((height + 15) / 16);
    const auto level_limit = static_cast<int>(std::max<std::int64_t>(1, max_macroblocks_per_second / macroblocks_per_frame));
    return std::min(framerate, level_limit);
  }

  std::unique_ptr<vt_encode_device_t> make_encode_device(pix_fmt_e pix_fmt, resolution_fn_t resolution_fn, const pixel_format_fn_t &pixel_format_fn) {
    if (pix_fmt != pix_fmt_e::nv12 && pix_fmt != pix_fmt_e::p010) {
      BOOST_LOG(error) << "Unsupported pixel format for the VideoToolbox encoder"sv;
      return nullptr;
    }

    auto device = std::make_unique<::vt_encode_device>();
    if (device->init(pix_fmt, std::move(resolution_fn), pixel_format_fn)) {
      return nullptr;
    }
    return device;
  }
}  // namespace platf::vt
