#!/bin/bash
# Builds "TellyBeam.app" and zips it for download. Run on a Mac with Xcode or its
# Command Line Tools:  bash mac-app/build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/TellyBeam.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/TVMirror" "$APP/Contents/MacOS/TVMirror"
cp Info.plist "$APP/Contents/Info.plist"

# App icon: make every size macOS needs from AppIcon.png, then pack them into AppIcon.icns
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# "Ad-hoc" signature: free, but macOS asks people to allow the app the first time
codesign --force --deep --sign - "$APP"

cd build
ditto -c -k --keepParent "TellyBeam.app" "TellyBeam-Mac.zip"
echo "Built: mac-app/build/TellyBeam-Mac.zip"
