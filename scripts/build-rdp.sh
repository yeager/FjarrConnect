#!/bin/bash
# Build the embedded FreeRDP view for one Mac architecture, with static dependencies.
set -euo pipefail
RDP_ARCH=${1:?Usage: build-rdp.sh arm64|x86_64}
case "$RDP_ARCH" in arm64) SSL_TARGET=darwin64-arm64-cc ;; x86_64) SSL_TARGET=darwin64-x86_64-cc ;; *) exit 2 ;; esac
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_KEY=$(printf '%s' "$ROOT" | shasum -a 256 | cut -c1-12)
if [ -n "${FJARRCONNECT_RDP_BUILD_ROOT:-}" ]; then
  case "$FJARRCONNECT_RDP_BUILD_ROOT" in
    /*) BUILD_ROOT=$FJARRCONNECT_RDP_BUILD_ROOT ;;
    *) echo "FJARRCONNECT_RDP_BUILD_ROOT must be an absolute path" >&2; exit 2 ;;
  esac
else
  # Keep CMake's source/build paths out of File Provider-managed Documents.
  BUILD_ROOT="/tmp/fjarrconnect-rdp-$ROOT_KEY"
fi
OWNER_FILE="$BUILD_ROOT/.fjarrconnect-root"
if [ -e "$BUILD_ROOT" ]; then
  if [ ! -f "$OWNER_FILE" ] || [ "$(cat "$OWNER_FILE")" != "$ROOT" ]; then
    echo "RDP build directory is not marked for this checkout: $BUILD_ROOT" >&2
    exit 1
  fi
else
  mkdir -p "$BUILD_ROOT"
  printf '%s\n' "$ROOT" > "$OWNER_FILE"
fi
STAGE="$BUILD_ROOT/build/rdp-$RDP_ARCH"
NATIVE_SOURCE="$BUILD_ROOT/NativeRDP"
PREFIX="$STAGE/install"
mkdir -p "$STAGE" "$NATIVE_SOURCE" "$PREFIX" "$ROOT/build/rdp-output/$RDP_ARCH/Licenses"
cp -R "$ROOT/NativeRDP/." "$NATIVE_SOURCE/"
export MACOSX_DEPLOYMENT_TARGET=14.0
fetch() {
  local name=$1 repo=$2 revision=$3
  if [ ! -d "$STAGE/$name/.git" ]; then
    git init -q "$STAGE/$name"
    git -C "$STAGE/$name" remote add origin "$repo"
  fi
  git -C "$STAGE/$name" fetch --depth 1 origin "$revision"
  git -C "$STAGE/$name" checkout -q --detach FETCH_HEAD
  test "$(git -C "$STAGE/$name" rev-parse HEAD)" = "$revision"
}
fetch openssl https://github.com/openssl/openssl.git f4dc4d58b48d346a8270183f89acf826d459b0ca
fetch FreeRDP https://github.com/FreeRDP/FreeRDP.git d27a4f7c1c63b62a5e60e5d939ad116cfb58ffc1
COMMON=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX"
  -DCMAKE_OSX_ARCHITECTURES="$RDP_ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF)
if [ ! -f "$PREFIX/.openssl-ready" ]; then
(
  cd "$STAGE/openssl"
  ./Configure "$SSL_TARGET" no-shared no-tests no-module --prefix="$PREFIX" --libdir=lib -mmacosx-version-min=14.0
  make -j3
  make install_sw
)
touch "$PREFIX/.openssl-ready"
fi
(
cd "$STAGE"
cmake -S "$NATIVE_SOURCE" -B "$STAGE/FreeRDP-build" -DFREERDP_SOURCE_DIR="$STAGE/FreeRDP" "${COMMON[@]}" \
  -DOPENSSL_ROOT_DIR="$PREFIX" -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DCHANNEL_URBDRC=OFF -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF -DBUILD_TESTING=OFF \
  -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_WEBVIEW=OFF -DWITH_MANPAGES=OFF \
  -DWITH_SWSCALE=OFF -DWITH_OPUS=OFF -DWITH_FFMPEG=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_VIDEO_FFMPEG=OFF -DWITH_OPENH264=OFF \
  -DWITH_JPEG=OFF -DWITH_GSM=OFF -DWITH_LAME=OFF -DWITH_FAAD2=OFF -DWITH_FAAC=OFF \
  -DWITH_SOXR=OFF -DWITH_AOM=OFF -DWITH_DAV1D=OFF -DWITH_YUV=OFF -DWITH_PCSC=OFF \
  -DWITH_CUPS=OFF -DWITH_FUSE=OFF -DWITH_KRB5=OFF -DWITH_PKCS11=OFF \
  -DWITH_CLANG_FORMAT=OFF \
  -DWITH_JSON_DISABLED=ON -DWITH_AAD=OFF -DWITH_FIDO=OFF -DWITH_CCACHE=OFF \
  -DWITH_AVX2=OFF -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF
# A previous local build may have been made from temporarily instrumented
# FreeRDP sources that were later restored with older timestamps. Force CMake
# to discard stale objects so the packaged runtime always matches pinned source.
cmake --build "$STAGE/FreeRDP-build" --clean-first --target FjarrRDP --parallel 3
)
BINARY="$STAGE/FreeRDP-build/libFjarrRDP.dylib"
test -f "$BINARY"
lipo "$BINARY" -verify_arch "$RDP_ARCH"
# No Homebrew or build-directory dylibs may escape into the downloadable app.
otool -L "$BINARY" | tail -n +2 | awk '{print $1}' | while IFS= read -r library; do
  case "$library" in @rpath/libFjarrRDP.dylib|/usr/lib/*|/System/Library/*) ;; *) echo "Non-system runtime dependency: $library" >&2; exit 1 ;; esac
done
cp "$BINARY" "$ROOT/build/rdp-output/$RDP_ARCH/libFjarrRDP.dylib"
LICENSES="$ROOT/build/rdp-output/$RDP_ARCH/Licenses"
cp "$STAGE/openssl/LICENSE.txt" "$LICENSES/OpenSSL.txt"
cp "$STAGE/FreeRDP/LICENSE" "$LICENSES/FreeRDP.txt"
find "$STAGE/FreeRDP/resources" -iname '*license*' -o -iname '*OFL*' | while IFS= read -r license; do
  cp "$license" "$LICENSES/FreeRDP-resource-$(basename "$license")"
done
# The packaged-runtime smoke test compiles a small probe against both the
# pinned public headers and CMake-generated configuration headers. Carry only
# those include trees in the artifact so clean release jobs can run the same
# test without rebuilding or cloning FreeRDP themselves.
SMOKE_HEADERS="$ROOT/build/rdp-output/$RDP_ARCH/SmokeHeaders"
for include in freerdp freerdp/winpr build/freerdp build/freerdp/winpr build/openssl; do
  mkdir -p "$SMOKE_HEADERS/$include/include"
done
cp -R "$STAGE/FreeRDP/include/." "$SMOKE_HEADERS/freerdp/include/"
cp -R "$STAGE/FreeRDP/winpr/include/." "$SMOKE_HEADERS/freerdp/winpr/include/"
cp -R "$STAGE/FreeRDP-build/freerdp/include/." "$SMOKE_HEADERS/build/freerdp/include/"
cp -R "$STAGE/FreeRDP-build/freerdp/winpr/include/." "$SMOKE_HEADERS/build/freerdp/winpr/include/"
cp -R "$PREFIX/include/openssl/." "$SMOKE_HEADERS/build/openssl/include/"
