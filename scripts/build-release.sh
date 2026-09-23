#!/bin/bash
set -euo pipefail
ARCH=${1:?Specify arm64 or x86_64}
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
mkdir -p dist
xcodebuild -project FjarrConnect.xcodeproj -scheme FjarrConnect \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "build/release-$ARCH" ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO build | xcbeautify
APP="build/release-$ARCH/Build/Products/Release/FjarrConnect.app"
test -d "$APP"
python3 scripts/check-resources.py --app "$APP"
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
ARTIFACT="build/rdp-artifacts/rdp-$ARCH"
OUTPUT="build/rdp-output/$ARCH"
RUNTIME_ROOT="$ARTIFACT"
if [ -f "$OUTPUT/libFjarrRDP.dylib" ] && { [ ! -f "$ARTIFACT/libFjarrRDP.dylib" ] || [ "$OUTPUT/libFjarrRDP.dylib" -nt "$ARTIFACT/libFjarrRDP.dylib" ]; }; then RUNTIME_ROOT="$OUTPUT"; fi
cp "$RUNTIME_ROOT/libFjarrRDP.dylib" "$APP/Contents/Frameworks/libFjarrRDP.dylib"
cp "$RUNTIME_ROOT/Licenses/"* "$APP/Contents/Resources/Licenses/"
# Every executable, including the required embedded VNC framework, is single-architecture.
test -f "$APP/Contents/Frameworks/RoyalVNCKit.framework/Versions/A/RoyalVNCKit"
while IFS= read -r binary; do
  if file "$binary" | grep -q 'Mach-O'; then
    test "$(lipo -archs "$binary")" = "$ARCH"
  fi
done < <(find "$APP/Contents" -type f)
# Ad-hoc signing is required for executable code on Apple Silicon.
# This is NOT Developer ID signing or notarization.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
python3 scripts/smoke-app.py "$APP"
python3 scripts/smoke-rdp.py "$APP/Contents/Frameworks/libFjarrRDP.dylib"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCHIVE="FjarrConnect-${VERSION}-macOS-${ARCH}.zip"
ditto -c -k --keepParent "$APP" "dist/$ARCHIVE"
(cd dist && shasum -a 256 "$ARCHIVE" > "SHA256SUMS-${ARCH}.txt")
