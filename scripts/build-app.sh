#!/usr/bin/env bash
#
# Build Bridge.app, the native desktop client (SwiftUI, native/macos).
#
#   ./scripts/build-app.sh            build into dist/Bridge.app
#   ./scripts/build-app.sh install    build, then copy to ~/Applications and open it
#
# Needs only the Xcode command line tools (swift build). The app talks to the
# server on BRIDGE_PORT and starts it under launchd if it isn't up.

set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="Bridge"
APP="$PROJ/dist/$NAME.app"
PORT="$(node -e 'process.stdout.write(String(require(process.argv[1]).port))' "$PROJ/lib/env.js")"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "building native/macos (swift build -c release)"
(cd "$PROJ/native/macos" && swift build -c release 2>&1 | grep -E "error|warning: |Compiling|Build complete" || true)
BIN="$(cd "$PROJ/native/macos" && swift build -c release --show-bin-path)/Bridge"
[[ -x "$BIN" ]] || { echo "error: build failed" >&2; exit 1; }
cp "$BIN" "$APP/Contents/MacOS/$NAME"

# App icon from public/logo.png.
ICONSET="$(mktemp -d)/$NAME.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$PROJ/native/macos/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$PROJ/native/macos/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$NAME.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>local.bridge.app</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(node -p 'require(process.argv[1]).version' "$PROJ/package.json")</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>BridgeRoot</key><string>$PROJ</string>
  <key>BridgePort</key><string>$PORT</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP (dashboard on :$PORT)"

if [[ "${1:-}" == "install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$NAME.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "installed ~/Applications/$NAME.app"
  open "$HOME/Applications/$NAME.app"
fi
