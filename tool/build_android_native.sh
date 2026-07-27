#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-release}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
WEBP_ROOT="${ZIC_ANDROID_WEBP_ROOT:-}"
API="${ZIC_ANDROID_API:-21}"
ABIS="${ZIC_ANDROID_ABIS:-arm64-v8a,armeabi-v7a,x86_64}"
LINK="${ZIC_ANDROID_WEBP_LINK:-shared}"

case "$MODE" in
  debug|release) ;;
  *)
    echo "usage: $0 [debug|release]" >&2
    exit 64
    ;;
esac
case "$LINK" in
  shared|static) ;;
  *)
    echo "ZIC_ANDROID_WEBP_LINK must be shared or static" >&2
    exit 64
    ;;
esac

if [[ -z "$NDK" || ! -d "$NDK/toolchains/llvm/prebuilt" ]]; then
  echo "ANDROID_NDK_HOME or ANDROID_NDK_ROOT must point to an Android NDK" >&2
  exit 1
fi
if [[ -z "$WEBP_ROOT" || ! -d "$WEBP_ROOT" ]]; then
  echo "ZIC_ANDROID_WEBP_ROOT must contain per-ABI libwebp directories" >&2
  exit 1
fi
for command in cargo rustup; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required" >&2
    exit 1
  fi
done

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) HOST_TAG=linux-x86_64 ;;
  Darwin-x86_64) HOST_TAG=darwin-x86_64 ;;
  Darwin-arm64) HOST_TAG=darwin-x86_64 ;;
  *)
    echo "unsupported NDK host: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
if [[ ! -d "$TOOLCHAIN" ]]; then
  echo "NDK toolchain not found: $TOOLCHAIN" >&2
  exit 1
fi

IFS=',' read -r -a ABI_LIST <<< "$ABIS"
for ABI in "${ABI_LIST[@]}"; do
  case "$ABI" in
    arm64-v8a)
      TARGET=aarch64-linux-android
      CLANG=aarch64-linux-android${API}-clang
      ;;
    armeabi-v7a)
      TARGET=armv7-linux-androideabi
      CLANG=armv7a-linux-androideabi${API}-clang
      ;;
    x86_64)
      TARGET=x86_64-linux-android
      CLANG=x86_64-linux-android${API}-clang
      ;;
    *)
      echo "unsupported ABI: $ABI" >&2
      exit 64
      ;;
  esac

  WEBP_LIB="$WEBP_ROOT/$ABI/lib"
  if [[ ! -d "$WEBP_LIB" ]]; then
    echo "missing libwebp directory: $WEBP_LIB" >&2
    exit 1
  fi
  if [[ "$LINK" == shared ]]; then
    for lib in libwebp.so libwebpdemux.so; do
      if [[ ! -e "$WEBP_LIB/$lib" ]]; then
        echo "missing shared dependency: $WEBP_LIB/$lib" >&2
        exit 1
      fi
    done
  else
    for lib in libwebp.a libwebpdemux.a; do
      if [[ ! -e "$WEBP_LIB/$lib" ]]; then
        echo "missing static dependency: $WEBP_LIB/$lib" >&2
        exit 1
      fi
    done
  fi

  rustup target add "$TARGET"
  ENV_TARGET="$(printf '%s' "$TARGET" | tr '[:lower:]-' '[:upper:]_')"
  export "CARGO_TARGET_${ENV_TARGET}_LINKER=$TOOLCHAIN/$CLANG"
  export CC="$TOOLCHAIN/$CLANG"
  export AR="$TOOLCHAIN/llvm-ar"
  export ZIC_WEBP_LIB_DIR="$WEBP_LIB"
  if [[ "$LINK" == static ]]; then
    export ZIC_WEBP_STATIC=1
    if [[ -e "$WEBP_LIB/libsharpyuv.a" ]]; then
      export ZIC_WEBP_EXTRA_LIBS=sharpyuv
    else
      unset ZIC_WEBP_EXTRA_LIBS || true
    fi
  else
    unset ZIC_WEBP_STATIC || true
    unset ZIC_WEBP_EXTRA_LIBS || true
  fi

  CARGO_ARGS=(build -p media_core --target "$TARGET")
  PROFILE=debug
  if [[ "$MODE" == release ]]; then
    CARGO_ARGS+=(--release)
    PROFILE=release
  fi
  cargo "${CARGO_ARGS[@]}"

  DEST="$ROOT/apps/app/android/app/src/main/jniLibs/$ABI"
  mkdir -p "$DEST"
  cp "$ROOT/target/$TARGET/$PROFILE/libmedia_core.so" "$DEST/libmedia_core.so"
  if [[ "$LINK" == shared ]]; then
    cp -L "$WEBP_LIB/libwebp.so" "$DEST/libwebp.so"
    cp -L "$WEBP_LIB/libwebpdemux.so" "$DEST/libwebpdemux.so"
    if [[ -e "$WEBP_LIB/libsharpyuv.so" ]]; then
      cp -L "$WEBP_LIB/libsharpyuv.so" "$DEST/libsharpyuv.so"
    fi
  fi
  printf 'Packaged native media libraries for %s in %s\n' "$ABI" "$DEST"
done

"$ROOT/tool/check_android_native.sh"
