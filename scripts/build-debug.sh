#!/bin/bash
set -euo pipefail
ARCH=${1:-$(uname -m)}
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
DERIVED_DATA=${DERIVED_DATA:-"build/debug-$ARCH"}
xcodebuild -project FjarrConnect.xcodeproj -scheme FjarrConnect \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO build
APP="$DERIVED_DATA/Build/Products/Debug/FjarrConnect.app"
ARTIFACT="build/rdp-artifacts/rdp-$ARCH/libFjarrRDP.dylib"
OUTPUT="build/rdp-output/$ARCH/libFjarrRDP.dylib"
# A locally rebuilt runtime must win over an older cached artifact. Clean CI
# checkouts have only the artifact and retain their reproducible input.
RUNTIME="$ARTIFACT"
if [ -f "$OUTPUT" ] && { [ ! -f "$ARTIFACT" ] || [ "$OUTPUT" -nt "$ARTIFACT" ]; }; then RUNTIME="$OUTPUT"; fi
test -f "$RUNTIME"
mkdir -p "$APP/Contents/Frameworks"
cp "$RUNTIME" "$APP/Contents/Frameworks/libFjarrRDP.dylib"
# macOS rejects newly copied executable code in an ad-hoc signed debug app on
# Apple Silicon. Sign after the copy, before the runtime smoke test.
codesign --force --sign - "$APP/Contents/Frameworks/libFjarrRDP.dylib"
python3 scripts/smoke-rdp.py "$APP/Contents/Frameworks/libFjarrRDP.dylib"
echo "$APP"
