#!/bin/bash
set -euo pipefail
mkdir -p dist
xcodebuild -project FjarrConnect.xcodeproj -scheme FjarrConnect \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/release ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build | xcbeautify
APP='build/release/Build/Products/Release/FjarrConnect.app'
test -d "$APP"
# Fail on missing slices in either the app or embedded dynamic frameworks.
while IFS= read -r binary; do
  if file "$binary" | grep -q 'Mach-O'; then
    lipo "$binary" -verify_arch arm64 x86_64
  fi
done < <(find "$APP/Contents" -type f)
# Ad-hoc signing is required for executable code on Apple Silicon.
# This is NOT Developer ID signing or notarization.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCHIVE="FjarrConnect-${VERSION}-macOS-universal.zip"
ditto -c -k --keepParent "$APP" "dist/$ARCHIVE"
(cd dist && shasum -a 256 "$ARCHIVE" > SHA256SUMS.txt)
