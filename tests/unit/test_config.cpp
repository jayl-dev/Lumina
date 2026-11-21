/**
 * @file tests/unit/test_config.cpp
 * @brief Tests for configuration parsing helpers.
 */

// test includes
#include "../tests_common.h"

// standard includes
#include <array>
#include <string_view>

// local includes
#include <src/config.h>
#include <src/utility.h>

using namespace std::literals;

/**
 * @brief Verify resolution-cap parsing accepts WIDTHxHEIGHT and rejects malformed values without writing outputs.
 */
TEST(ConfigStreamResolutionTest, ParsesMaxStreamResolutionAndRejectsMalformedValues) {
  int width = 0;
  int height = 0;
  ASSERT_TRUE(config::parse_stream_resolution("2560x1440"sv, width, height));
  EXPECT_EQ(width, 2560);
  EXPECT_EQ(height, 1440);

  constexpr std::array malformed {
    "2560"sv,
    "2560x"sv,
    "x1440"sv,
    "0x1440"sv,
    "2560x0"sv,
    "1x1440"sv,
    "2560x1"sv,
    "-2560x1440"sv,
    "2560x1440x"sv,
    "2560 x 1440"sv,
    "widthxheight"sv,
  };
  for (const auto setting : malformed) {
    width = 1;
    height = 1;
    EXPECT_FALSE(config::parse_stream_resolution(setting, width, height)) << setting;
    EXPECT_EQ(width, 1) << setting;
    EXPECT_EQ(height, 1) << setting;
  }
}

/**
 * @brief Expected outcome of capping one client-requested resolution.
 */
struct StreamResolutionCapCase {
  int max_width;  ///< Configured maximum width.
  int max_height;  ///< Configured maximum height.
  int width;  ///< Client-requested width.
  int height;  ///< Client-requested height.
  bool capped;  ///< Whether the cap applies.
  int expected_width;  ///< Width after capping.
  int expected_height;  ///< Height after capping.
};

/**
 * @brief Parameterized fixture for config::cap_stream_resolution.
 */
struct StreamResolutionCapTest: testing::TestWithParam<StreamResolutionCapCase> {};

/**
 * @brief Verify resolution caps preserve aspect ratio and produce even dimensions while leaving uncapped requests unchanged.
 */
TEST_P(StreamResolutionCapTest, CapsPreservingAspectRatioWithEvenDimensions) {
  const auto original_video = config::video;
  const auto restore_video = util::fail_guard([original_video]() {
    config::video = original_video;
  });
  const auto &param = GetParam();
  config::video.max_stream_width = param.max_width;
  config::video.max_stream_height = param.max_height;

  int width = param.width;
  int height = param.height;
  EXPECT_EQ(config::cap_stream_resolution(width, height), param.capped);
  EXPECT_EQ(width, param.expected_width);
  EXPECT_EQ(height, param.expected_height);
}

INSTANTIATE_TEST_SUITE_P(
  ConfigCapStreamResolution,
  StreamResolutionCapTest,
  testing::Values(
    // Disabled cap
    StreamResolutionCapCase {0, 0, 3840, 2160, false, 3840, 2160},
    StreamResolutionCapCase {2560, 0, 3840, 2160, false, 3840, 2160},
    // Requests within the cap are untouched
    StreamResolutionCapCase {2560, 1440, 2560, 1440, false, 2560, 1440},
    StreamResolutionCapCase {2560, 1440, 1920, 1080, false, 1920, 1080},
    // Invalid requests are untouched
    StreamResolutionCapCase {2560, 1440, 0, 2160, false, 0, 2160},
    // Same aspect ratio lands exactly on the cap
    StreamResolutionCapCase {2560, 1440, 3840, 2160, true, 2560, 1440},
    // Width-limited ultrawide: 1440 * 2560 / 3440 = 1071.6, rounded down to even
    StreamResolutionCapCase {2560, 1440, 3440, 1440, true, 2560, 1070},
    // Height-limited portrait request
    StreamResolutionCapCase {2560, 1440, 2160, 3840, true, 810, 1440},
    // A single dimension over the cap still scales both
    StreamResolutionCapCase {1920, 1080, 1920, 1200, true, 1728, 1080},
    // Floating-point scaling used to land two pixels short of the cap here
    StreamResolutionCapCase {1280, 720, 640, 1142, true, 402, 720},
    // Extreme aspect ratios never collapse to zero
    StreamResolutionCapCase {100, 100, 10000, 2, true, 100, 2}
  )
);
