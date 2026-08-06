#!/usr/bin/env bash
set -euo pipefail

num_processors=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
publisher_name="jayl-dev"
publisher_website="https://github.com/jayl-dev/Lumina"
publisher_issue_url="https://github.com/jayl-dev/Lumina/issues"
step="all"
build_docs="OFF"
build_tests="OFF"
build_type="Release"

BUILD_VERSION=""
BRANCH=$(git rev-parse --abbrev-ref HEAD)
COMMIT=$(git rev-parse --short HEAD)
export BUILD_VERSION BRANCH COMMIT

required_formulas=(
  "cmake" "node" "pkgconf" "icu4c@78" "miniupnpc" "openssl@3" "opus"
)

function _usage() {
  local exit_code=$1
  cat <<EOF
Build and package Lumina as a portable macOS command-line ZIP.

Usage: $0 [options]

Options:
  -h, --help               Display this help message.
  --num-processors=N       Number of compilation workers (default: ${num_processors}).
  --step=STEP              deps, cmake, build, zip, or all (default: all).
  --debug                  Build in debug mode.
  --build-docs             Build documentation.
  --build-tests            Build tests.

The ZIP contains lumina, vd_helper, assets, and hid_entitlements.plist.
It is intentionally unsigned so users can opt into local ad-hoc HID signing.
EOF
  exit "$exit_code"
}

function run_step_deps() {
  brew update
  brew install "${required_formulas[@]}"
}

function run_step_cmake() {
  local cmake_args=(
    "-B=${build_dir}"
    "-S=."
    "-DBUILD_DOCS=${build_docs}"
    "-DBUILD_TESTS=${build_tests}"
    "-DBUILD_WERROR=ON"
    "-DCMAKE_BUILD_TYPE=${build_type}"
    "-DICU_ROOT=$(brew --prefix icu4c@78 2>/dev/null)"
    "-DOPENSSL_ROOT_DIR=$(brew --prefix openssl@3 2>/dev/null)"
    "-DOpus_ROOT_DIR=$(brew --prefix opus 2>/dev/null)"
    "-DSUNSHINE_ASSETS_DIR=assets"
    "-DSUNSHINE_BUILD_HOMEBREW=OFF"
    "-DSUNSHINE_ENABLE_TRAY=ON"
    "-DSUNSHINE_PACKAGE_MACOS=ON"
    "-DSUNSHINE_PUBLISHER_NAME=${publisher_name}"
    "-DSUNSHINE_PUBLISHER_WEBSITE=${publisher_website}"
    "-DSUNSHINE_PUBLISHER_ISSUE_URL=${publisher_issue_url}"
  )

  cmake "${cmake_args[@]}"
}

function run_step_build() {
  cmake --build "${build_dir}" --target sunshine web-ui vd_helper --parallel "${num_processors}"
}

function run_step_zip() {
  cpack -G ZIP --config "${build_dir}/CPackConfig.cmake" --verbose
}

function run_install() {
  case "$step" in
    deps) run_step_deps ;;
    cmake) run_step_cmake ;;
    build) run_step_build ;;
    zip) run_step_zip ;;
    all)
      run_step_cmake
      run_step_build
      run_step_zip
      ;;
    *)
      echo "Invalid step: $step" >&2
      _usage 1
      ;;
  esac
}

while getopts ":h-:" opt; do
  case ${opt} in
    h) _usage 0 ;;
    -)
      case "${OPTARG}" in
        help) _usage 0 ;;
        num-processors=*) num_processors="${OPTARG#*=}" ;;
        step=*) step="${OPTARG#*=}" ;;
        debug) build_type="Debug" ;;
        build-docs) build_docs="ON" ;;
        build-tests) build_tests="ON" ;;
        *) echo "Invalid option: --${OPTARG}" >&2; _usage 1 ;;
      esac
      ;;
    \?) echo "Invalid option: -${OPTARG}" >&2; _usage 1 ;;
  esac
done
shift $((OPTIND - 1))

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
build_dir="${script_dir}/../build-macos-zip"
mkdir -p "${build_dir}"
run_install
