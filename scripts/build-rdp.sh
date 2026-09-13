#!/bin/bash
# Build an isolated, statically linked FreeRDP SDL client for one Mac architecture.
set -euo pipefail
RDP_ARCH=${1:?Usage: build-rdp.sh arm64|x86_64}
case "$RDP_ARCH" in arm64) SSL_TARGET=darwin64-arm64-cc ;; x86_64) SSL_TARGET=darwin64-x86_64-cc ;; *) exit 2 ;; esac
ROOT=$(pwd)
STAGE="$ROOT/build/rdp-$RDP_ARCH"
PREFIX="$STAGE/install"
mkdir -p "$STAGE" "$PREFIX" "$ROOT/build/rdp-output/$RDP_ARCH/Licenses"
export MACOSX_DEPLOYMENT_TARGET=14.0
fetch() {
  local name=$1 repo=$2 revision=$3
  if [ ! -d "$STAGE/$name/.git" ]; then
    git init -q "$STAGE/$name"
    git -C "$STAGE/$name" remote add origin "$repo"
    git -C "$STAGE/$name" fetch --depth 1 origin "$revision"
    git -C "$STAGE/$name" checkout --detach FETCH_HEAD
  fi
  test "$(git -C "$STAGE/$name" rev-parse HEAD)" = "$revision"
}
fetch openssl https://github.com/openssl/openssl.git f4dc4d58b48d346a8270183f89acf826d459b0ca
fetch SDL https://github.com/libsdl-org/SDL.git fa2c02bb6e21974a89ea9824bc53c9932abe5f9c
fetch SDL_ttf https://github.com/libsdl-org/SDL_ttf.git a1ce3670aec736ecbf0936c43f2f0cc53aa61e5b
fetch FreeRDP https://github.com/FreeRDP/FreeRDP.git 63b948ca5cb94307fd5444ee6e73927a41ccdab4
COMMON=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX"
  -DCMAKE_OSX_ARCHITECTURES="$RDP_ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF)
git -C "$STAGE/SDL_ttf" submodule update --init --depth 1 external/freetype
if [ ! -f "$PREFIX/.dependencies-ready" ]; then
(
  cd "$STAGE/openssl"
  ./Configure "$SSL_TARGET" no-shared no-tests no-module --prefix="$PREFIX" --libdir=lib -mmacosx-version-min=14.0
  make -j3
  make install_sw
)
cmake -S "$STAGE/SDL" -B "$STAGE/SDL-build" "${COMMON[@]}" \
  -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
cmake --build "$STAGE/SDL-build" --parallel 3
cmake --install "$STAGE/SDL-build"
cmake -S "$STAGE/SDL_ttf" -B "$STAGE/SDL_ttf-build" "${COMMON[@]}" \
  -DSDLTTF_VENDORED=ON -DSDLTTF_HARFBUZZ=OFF -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_SAMPLES=OFF \
  -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON
cmake --build "$STAGE/SDL_ttf-build" --parallel 3
cmake --install "$STAGE/SDL_ttf-build"
touch "$PREFIX/.dependencies-ready"
fi
cmake -S "$STAGE/FreeRDP" -B "$STAGE/FreeRDP-build" "${COMMON[@]}" \
  -DOPENSSL_ROOT_DIR="$PREFIX" -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DWITH_CLIENT_SDL=ON -DWITH_CLIENT_SDL2=OFF -DWITH_CLIENT_SDL3=ON \
  -DWITH_SDL_LINK_SHARED=OFF -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF -DBUILD_TESTING=OFF \
  -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_WEBVIEW=OFF -DWITH_MANPAGES=OFF \
  -DWITH_SWSCALE=OFF -DWITH_OPUS=OFF -DWITH_FFMPEG=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_VIDEO_FFMPEG=OFF -DWITH_OPENH264=OFF \
  -DWITH_JPEG=OFF -DWITH_GSM=OFF -DWITH_LAME=OFF -DWITH_FAAD2=OFF -DWITH_FAAC=OFF \
  -DWITH_SOXR=OFF -DWITH_AOM=OFF -DWITH_DAV1D=OFF -DWITH_YUV=OFF -DWITH_PCSC=OFF \
  -DWITH_CUPS=OFF -DWITH_FUSE=OFF -DWITH_KRB5=OFF -DWITH_PKCS11=OFF \
  -DWITH_JSON_DISABLED=ON -DWITH_AAD=OFF -DWITH_FIDO=OFF -DWITH_CCACHE=OFF \
  -DWITH_AVX2=OFF -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF
cmake --build "$STAGE/FreeRDP-build" --target sdl3-freerdp --parallel 3
BINARY=$(find "$STAGE/FreeRDP-build" -type f -name sdl-freerdp -perm -111 | head -1)
test -n "$BINARY"
lipo "$BINARY" -verify_arch "$RDP_ARCH"
# No Homebrew or build-directory dylibs may escape into the downloadable app.
otool -L "$BINARY" | tail -n +2 | awk '{print $1}' | while IFS= read -r library; do
  case "$library" in /usr/lib/*|/System/Library/*) ;; *) echo "Non-system runtime dependency: $library" >&2; exit 1 ;; esac
done
cp "$BINARY" "$ROOT/build/rdp-output/$RDP_ARCH/sdl-freerdp"
LICENSES="$ROOT/build/rdp-output/$RDP_ARCH/Licenses"
cp "$STAGE/openssl/LICENSE.txt" "$LICENSES/OpenSSL.txt"
cp "$STAGE/SDL/LICENSE.txt" "$LICENSES/SDL.txt"
cp "$STAGE/SDL_ttf/LICENSE.txt" "$LICENSES/SDL_ttf.txt"
cp "$STAGE/SDL_ttf/external/freetype/docs/FTL.TXT" "$LICENSES/FreeType.txt"
cp "$STAGE/FreeRDP/LICENSE" "$LICENSES/FreeRDP.txt"
find "$STAGE/FreeRDP/resources" -iname '*license*' -o -iname '*OFL*' | while IFS= read -r license; do
  cp "$license" "$LICENSES/FreeRDP-resource-$(basename "$license")"
done
