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
RUNTIME="build/rdp-artifacts/rdp-$ARCH/libFjarrRDP.dylib"
if [ ! -f "$RUNTIME" ]; then RUNTIME="build/rdp-output/$ARCH/libFjarrRDP.dylib"; fi
test -f "$RUNTIME"
mkdir -p "$APP/Contents/Frameworks"
cp "$RUNTIME" "$APP/Contents/Frameworks/libFjarrRDP.dylib"
python3 scripts/smoke-rdp.py "$APP/Contents/Frameworks/libFjarrRDP.dylib"
echo "$APP"
