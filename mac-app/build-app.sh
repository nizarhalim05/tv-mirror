#!/bin/bash
# Builds "TV Mirror.app" and zips it for download. Run on a Mac with Xcode or its
# Command Line Tools:  bash mac-app/build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/TV Mirror.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/TVMirror" "$APP/Contents/MacOS/TVMirror"
cp Info.plist "$APP/Contents/Info.plist"

# "Ad-hoc" signature: free, but macOS asks people to allow the app the first time
codesign --force --deep --sign - "$APP"

cd build
ditto -c -k --keepParent "TV Mirror.app" "TV-Mirror-Mac.zip"
echo "Built: mac-app/build/TV-Mirror-Mac.zip"
