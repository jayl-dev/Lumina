/**
 * @file tests/integration/test_config_consistency.cpp
 * @brief Test configuration consistency between config.cpp, the Web UI settings registry, and its labels.
 */
// test includes
#include "../tests_common.h"

// standard includes
#include <algorithm>
#include <format>
#include <map>
#include <regex>
#include <set>
#include <string>
#include <vector>

// lib includes
#include <nlohmann/json.hpp>

// local includes
#include "src/file_handler.h"

namespace {
  using option_set_t = std::set<std::string, std::less<>>;

  // Parsed by config.cpp but deliberately left out of the Web UI
  const option_set_t backend_only_options {
    "ds5_inputtino_randomize_mac",  // Linux inputtino backend; not used by the macOS build
    "streaming_performance_logging",  // Lumina diagnostics switch, set by hand while profiling
  };

  // Shown by the upstream Web UI only on Windows or Linux, where Lumina has no backend for them
  const option_set_t non_macos_ui_options {
    "amd_max_au_size",
    "external_audio",
    "fp16_sdr_gamma_encoded",
    "gamepad_driver",
    "nvenc_split_encode",
    "vaapi_blbrc",
    "vaapi_quality",
    "vaapi_rc",
    "virtualhid_randomize_mac",
    "vk_quality",
    "vk_rc_mode",
    "vk_tune",
  };

  /**
   * @brief Extract the option names config.cpp reads, the authoritative list.
   */
  option_set_t config_cpp_options() {
    const std::string content = file_handler::read_file("src/config.cpp");
    const std::regex pattern(R"DELIM((?:string_f|path_f|string_restricted_f|string_list_f|int_f|int_between_f|bool_f|double_f|double_between_f|generic_f|list_prep_cmd_f|map_int_int_f)\s*\(\s*vars\s*,\s*"([^"]+)")DELIM");

    option_set_t options;
    for (std::sregex_iterator it(content.begin(), content.end(), pattern), end; it != end; ++it) {
      options.insert((*it)[1].str());
    }
    return options;
  }

  /**
   * @brief Map each Web UI option to the settings tab that owns it.
   */
  std::map<std::string, std::string, std::less<>> config_tab_options() {
    const auto tabs = nlohmann::json::parse(file_handler::read_file("src_assets/common/assets/web/configs/config_tabs.json"));

    std::map<std::string, std::string, std::less<>> options;
    for (const auto &tab : tabs) {
      for (const auto &[name, default_value] : tab.at("options").items()) {
        options.emplace(name, tab.at("id").get<std::string>());
      }
    }
    return options;
  }

  /**
   * @brief Collect the option labels defined in the English locale.
   */
  option_set_t en_json_config_keys() {
    const auto locale = nlohmann::json::parse(file_handler::read_file("src_assets/common/assets/web/public/assets/locale/en.json"));

    option_set_t keys;
    for (const auto &[key, value] : locale.at("config").items()) {
      keys.insert(key);
    }
    return keys;
  }

  std::string join(const std::vector<std::string> &items) {
    std::string result;
    for (const auto &item : items) {
      result += result.empty() ? item : ", " + item;
    }
    return result;
  }
}  // namespace

TEST(ConfigConsistencyTest, EveryBackendOptionHasAWebUiDefault) {
  const auto ui_options = config_tab_options();

  std::vector<std::string> missing;
  for (const auto &option : config_cpp_options()) {
    if (!backend_only_options.contains(option) && !ui_options.contains(option)) {
      missing.push_back(option);
    }
  }
  EXPECT_TRUE(missing.empty()) << "config_tabs.json is missing: " << join(missing);
}

TEST(ConfigConsistencyTest, EveryBackendOptionHasAnEnglishLabel) {
  const auto labels = en_json_config_keys();

  std::vector<std::string> missing;
  for (const auto &option : config_cpp_options()) {
    if (!backend_only_options.contains(option) && !labels.contains(option)) {
      missing.push_back(option);
    }
  }
  EXPECT_TRUE(missing.empty()) << "en.json is missing: " << join(missing);
}

TEST(ConfigConsistencyTest, EveryWebUiOptionHasAnEnglishLabel) {
  const auto labels = en_json_config_keys();

  std::vector<std::string> missing;
  for (const auto &[option, tab] : config_tab_options()) {
    if (!labels.contains(option)) {
      missing.push_back(std::format("{} ({})", option, tab));
    }
  }
  EXPECT_TRUE(missing.empty()) << "en.json is missing: " << join(missing);
}

TEST(ConfigConsistencyTest, WebUiOnlyShowsOptionsTheBackendReads) {
  const auto backend = config_cpp_options();

  std::vector<std::string> unknown;
  for (const auto &[option, tab] : config_tab_options()) {
    if (!backend.contains(option) && !non_macos_ui_options.contains(option)) {
      unknown.push_back(std::format("{} ({})", option, tab));
    }
  }
  EXPECT_TRUE(unknown.empty()) << "config_tabs.json has options config.cpp never reads: " << join(unknown);
}
