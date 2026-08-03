#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/native/libwebp.lock"
MODE="${1:-release}"
LINK="${ZIC_WEBP_HOST_LINK:-shared}"
DEPS="${ZIC_DEPS_DIR:-$ROOT/.deps}"
PATCH_SHA="$(sha256sum "$ROOT/native/patches/libwebp-vp8-thread-buffer-pool-v1.6.0.patch" | awk '{print $1}')"

case "$MODE" in
  debug|release) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 64 ;;
esac
case "$LINK" in
  shared|static) ;;
  *) echo "ZIC_WEBP_HOST_LINK must be shared or static" >&2; exit 64 ;;
esac
for command in cmake ninja git; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required to build libwebp from source" >&2
    exit 1
  }
done

SOURCE="$("$ROOT/tool/prepare_webp.sh")"
BUILD_TYPE=Release
[[ "$MODE" == debug ]] && BUILD_TYPE=Debug
BUILD="$DEPS/build/libwebp/host/$WEBP_VERSION/$MODE/$LINK"
PREFIX="$DEPS/install/libwebp/host/$WEBP_VERSION/$MODE/$LINK"
CONFIG_ID="$WEBP_COMMIT|$PATCH_SHA|host|$BUILD_TYPE|$LINK"
if [[ -f "$BUILD/.zic-config" && "$(cat "$BUILD/.zic-config")" != "$CONFIG_ID" ]]; then
  rm -rf "$BUILD" "$PREFIX"
fi
mkdir -p "$BUILD"
printf '%s' "$CONFIG_ID" > "$BUILD/.zic-config"

SHARED=ON
[[ "$LINK" == static ]] && SHARED=OFF
cmake -S "$SOURCE" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS="$SHARED" \
  -DWEBP_LINK_STATIC=$([[ "$LINK" == static ]] && echo ON || echo OFF) \
  -DWEBP_BUILD_ANIM_UTILS=OFF \
  -DWEBP_BUILD_CWEBP=OFF \
  -DWEBP_BUILD_DWEBP=OFF \
  -DWEBP_BUILD_GIF2WEBP=OFF \
  -DWEBP_BUILD_IMG2WEBP=OFF \
  -DWEBP_BUILD_VWEBP=OFF \
  -DWEBP_BUILD_WEBPINFO=OFF \
  -DWEBP_BUILD_LIBWEBPMUX=OFF \
  -DWEBP_BUILD_WEBPMUX=OFF \
  -DWEBP_BUILD_EXTRAS=OFF \
  -DWEBP_BUILD_FUZZTEST=OFF \
  -DWEBP_BUILD_WEBP_JS=OFF
cmake --build "$BUILD" --target install --parallel

EXT=so
[[ "$(uname -s)" == Darwin ]] && EXT=dylib
[[ "$LINK" == static ]] && EXT=a
for lib in webp webpdemux; do
  find "$PREFIX/lib" -maxdepth 1 \( -type f -o -type l \) | grep -Eq "/lib${lib}\.${EXT}(\.|$)" || {
    echo "source build did not install lib${lib}.${EXT} under $PREFIX/lib" >&2
    exit 1
  }
done
printf 'Built libwebp %s from source for host: %s\n' "$WEBP_VERSION" "$PREFIX" >&2
printf '%s\n' "$PREFIX"
