#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/native/libwebp.lock"
ABI="${1:-}"
MODE="${2:-release}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
API="${ZIC_ANDROID_API:-21}"
LINK="${ZIC_ANDROID_WEBP_LINK:-static}"
DEPS="${ZIC_DEPS_DIR:-$ROOT/.deps}"
PATCH_SHA="$(sha256sum "$ROOT/native/patches/libwebp-vp8-thread-buffer-pool-v1.6.0.patch" | awk '{print $1}')"

case "$ABI" in arm64-v8a|armeabi-v7a|x86_64) ;; *) echo "usage: $0 <arm64-v8a|armeabi-v7a|x86_64> [debug|release]" >&2; exit 64 ;; esac
case "$MODE" in debug|release) ;; *) echo "usage: $0 <abi> [debug|release]" >&2; exit 64 ;; esac
case "$LINK" in shared|static) ;; *) echo "ZIC_ANDROID_WEBP_LINK must be shared or static" >&2; exit 64 ;; esac
[[ -n "$NDK" && -f "$NDK/build/cmake/android.toolchain.cmake" ]] || {
  echo "ANDROID_NDK_HOME or ANDROID_NDK_ROOT must point to an Android NDK" >&2
  exit 1
}
for command in cmake ninja git; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required to build Android libwebp from source" >&2
    exit 1
  }
done

SOURCE="$("$ROOT/tool/prepare_webp.sh")"
BUILD_TYPE=Release
[[ "$MODE" == debug ]] && BUILD_TYPE=Debug
BUILD="$DEPS/build/libwebp/android/$WEBP_VERSION/$ABI/$MODE/$LINK"
PREFIX="$DEPS/install/libwebp/android/$WEBP_VERSION/$ABI/$MODE/$LINK"
CONFIG_ID="$WEBP_COMMIT|$PATCH_SHA|$ABI|android-$API|$BUILD_TYPE|$LINK|$NDK"
if [[ -f "$BUILD/.zic-config" && "$(cat "$BUILD/.zic-config")" != "$CONFIG_ID" ]]; then
  rm -rf "$BUILD" "$PREFIX"
fi
mkdir -p "$BUILD"
printf '%s' "$CONFIG_ID" > "$BUILD/.zic-config"

SHARED=ON
[[ "$LINK" == static ]] && SHARED=OFF
cmake -S "$SOURCE" -B "$BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_NDK="$NDK" \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM="android-$API" \
  -DANDROID_STL=none \
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
[[ "$LINK" == static ]] && EXT=a
for lib in webp webpdemux; do
  find "$PREFIX/lib" -maxdepth 1 \( -type f -o -type l \) | grep -Eq "/lib${lib}\.${EXT}(\.|$)" || {
    echo "Android source build did not install lib${lib}.${EXT} for $ABI" >&2
    exit 1
  }
done
printf 'Built libwebp %s from source for %s: %s\n' "$WEBP_VERSION" "$ABI" "$PREFIX" >&2
printf '%s\n' "$PREFIX"
