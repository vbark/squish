#!/bin/zsh
# Builds build/Squish.app from the Swift package. Works with Command Line Tools or Xcode.
#   Scripts/bundle.sh                 release build, ad-hoc signed
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" Scripts/bundle.sh
set -euo pipefail
[[ -d /Applications/Xcode.app ]] && export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "${0:A:h}/.."

CONFIG=${CONFIG:-release}
APP=build/Squish.app
IDENTITY=${SIGN_IDENTITY:--}

swift build -c "$CONFIG" --product Squish
BIN=$(swift build -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN/Squish" "$APP/Contents/MacOS/Squish"
cp Support/Info.plist "$APP/Contents/Info.plist"

# App icon from assets/icon.svg (sips renders SVG on macOS 14+).
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -s format png -z $size $size assets/icon.svg --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -s format png -z $((size * 2)) $((size * 2)) assets/icon.svg --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "warning: icon not generated"

if [[ -d Vendor/bin ]] && [[ -n "$(ls Vendor/bin)" ]]; then
  cp Vendor/bin/* "$APP/Contents/Resources/bin/"
else
  echo "warning: Vendor/bin is empty. Run Scripts/build-tools.sh, or optimizations will report missing tools."
fi

# Sign inside out: bundled tools first, then the app. Hardened runtime only with a real identity.
RUNTIME=()
[[ "$IDENTITY" != "-" ]] && RUNTIME=(--options runtime --timestamp)
for tool in "$APP"/Contents/Resources/bin/*(N); do
  codesign --force --sign "$IDENTITY" "${RUNTIME[@]}" "$tool"
done
codesign --force --sign "$IDENTITY" "${RUNTIME[@]}" "$APP"
echo "Built $APP"
