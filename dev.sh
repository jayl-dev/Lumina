#!/bin/bash
set -e

lumina_perf_logging=OFF

case "${1:-}" in
  "")
    ;;
  performance)
    lumina_perf_logging=ON
    ;;
  *)
    echo "Usage: $0 [performance]" >&2
    exit 2
    ;;
esac

if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [performance]" >&2
  exit 2
fi

cmake -S . -B build \
  -DBUILD_DOCS=OFF \
  -DCMAKE_PREFIX_PATH="$(brew --prefix qtbase);$(brew --prefix qtsvg)" \
  -DQt6Svg_DIR="$(brew --prefix qtsvg)/lib/cmake/Qt6Svg" \
  -DLUMINA_ENABLE_STREAM_PERF_LOGGING="$lumina_perf_logging"
npm run build-clean
cmake --build build --target sunshine vd_helper --parallel 4

INSTALL_DIR="$HOME/.local/share/lumina"
mkdir -p "$INSTALL_DIR/assets/web"
cp -f build/lumina "$INSTALL_DIR/lumina"
cp -f build/vd_helper "$INSTALL_DIR/vd_helper"
cp -f hid_entitlements.plist "$INSTALL_DIR/hid_entitlements.plist"
cp -Rf build/assets/. "$INSTALL_DIR/assets/"

# Sign for gamepad support only if AMFI is disabled. With AMFI enabled, the
# restricted HID entitlement causes macOS to kill the process on launch.
if nvram boot-args 2>/dev/null | grep -q "amfi_get_out_of_my_way=1"; then
  codesign --sign - --entitlements "$INSTALL_DIR/hid_entitlements.plist" --force "$INSTALL_DIR/lumina"
  codesign --sign - --force "$INSTALL_DIR/vd_helper"
else
  echo "AMFI is enabled — skipping code signing (virtual HID gamepad unavailable; ESP32 board and keyboard emulation still work)."
fi
