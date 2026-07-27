#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/native/libwebp.lock"
MODE="${1:-release}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
API="${ZIC_ANDROID_API:-21}"
ABIS="${ZIC_ANDROID_ABIS:-arm64-v8a,armeabi-v7a,x86_64}"
LINK="${ZIC_ANDROID_WEBP_LINK:-static}"
DEPS="${ZIC_DEPS_DIR:-$ROOT/.deps}"

case "$MODE" in
  debug|release) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 64 ;;
esac
case "$LINK" in
  shared|static) ;;
  *) echo "ZIC_ANDROID_WEBP_LINK must be shared or static" >&2; exit 64 ;;
esac
[[ -n "$NDK" && -d "$NDK/toolchains/llvm/prebuilt" ]] || {
  echo "ANDROID_NDK_HOME or ANDROID_NDK_ROOT must point to an Android NDK" >&2
  exit 1
}
for command in cargo rustup cmake ninja git; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required" >&2
    exit 1
  }
done

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) HOST_TAG=linux-x86_64 ;;
  Darwin-x86_64) HOST_TAG=darwin-x86_64 ;;
  Darwin-arm64)
    if [[ -d "$NDK/toolchains/llvm/prebuilt/darwin-arm64" ]]; then
      HOST_TAG=darwin-arm64
    else
      HOST_TAG=darwin-x86_64
    fi
    ;;
  *) echo "unsupported NDK host: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
[[ -d "$TOOLCHAIN" ]] || {
  echo "NDK toolchain not found: $TOOLCHAIN" >&2
  exit 1
}

if [[ ! -d "$ROOT/apps/app/android" ]]; then
  "$ROOT/tool/bootstrap_platforms.sh"
fi

SOURCE="$("$ROOT/tool/fetch_webp.sh")"
NOTICE="$ROOT/apps/app/android/app/src/main/assets/third_party/libwebp"
mkdir -p "$NOTICE"
cp "$SOURCE/COPYING" "$NOTICE/COPYING"
cp "$SOURCE/PATENTS" "$NOTICE/PATENTS"
cat > "$NOTICE/SOURCE.txt" <<NOTICE_EOF
libwebp $WEBP_VERSION
Tag: $WEBP_TAG
Commit: $WEBP_COMMIT
Repository: $WEBP_REPO
Built from source by tool/build_webp_android.sh.
NOTICE_EOF

IFS=',' read -r -a ABI_LIST <<< "$ABIS"
for ABI in "${ABI_LIST[@]}"; do
  ABI="${ABI//[[:space:]]/}"
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
    *) echo "unsupported ABI: $ABI" >&2; exit 64 ;;
  esac

  "$ROOT/tool/build_webp_android.sh" "$ABI" "$MODE" >/dev/null
  WEBP_PREFIX="$DEPS/install/libwebp/android/$WEBP_VERSION/$ABI/$MODE/$LINK"
  WEBP_LIB="$WEBP_PREFIX/lib"

  rustup target add "$TARGET"
  ENV_TARGET="$(printf '%s' "$TARGET" | tr '[:lower:]-' '[:upper:]_')"
  export "CARGO_TARGET_${ENV_TARGET}_LINKER=$TOOLCHAIN/$CLANG"
  export CC="$TOOLCHAIN/$CLANG"
  export AR="$TOOLCHAIN/llvm-ar"
  export ZIC_WEBP_LIB_DIR="$WEBP_LIB"
  if [[ "$LINK" == static ]]; then
    export ZIC_WEBP_STATIC=1
    EXTRAS=()
    for lib in sharpyuv cpufeatures-webp; do
      [[ -e "$WEBP_LIB/lib$lib.a" ]] && EXTRAS+=("$lib")
    done
    if ((${#EXTRAS[@]})); then
      export ZIC_WEBP_EXTRA_LIBS="$(IFS=,; echo "${EXTRAS[*]}")"
    else
      unset ZIC_WEBP_EXTRA_LIBS || true
    fi
    export ZIC_WEBP_SYSTEM_LIBS=m,log,dl
  else
    unset ZIC_WEBP_STATIC || true
    unset ZIC_WEBP_EXTRA_LIBS || true
    unset ZIC_WEBP_SYSTEM_LIBS || true
  fi

  CARGO_ARGS=(build -p media_core --target "$TARGET")
  PROFILE=debug
  if [[ "$MODE" == release ]]; then
    CARGO_ARGS+=(--release)
    PROFILE=release
  fi
  cargo "${CARGO_ARGS[@]}"

  DEST="$ROOT/apps/app/android/app/src/main/jniLibs/$ABI"
  rm -rf "$DEST"
  mkdir -p "$DEST"
  cp "$ROOT/target/$TARGET/$PROFILE/libmedia_core.so" "$DEST/libmedia_core.so"
  if [[ "$LINK" == shared ]]; then
    for lib in webp webpdemux sharpyuv; do
      MATCH="$(find "$WEBP_LIB" -maxdepth 1 \( -type f -o -type l \) -name "lib$lib.so*" | sort | head -1 || true)"
      if [[ -n "$MATCH" ]]; then
        cp -L "$MATCH" "$DEST/lib$lib.so"
      elif [[ "$lib" != sharpyuv ]]; then
        echo "missing source-built shared dependency: lib$lib.so for $ABI" >&2
        exit 1
      fi
    done
  fi
  printf 'Packaged source-built native media libraries for %s in %s\n' "$ABI" "$DEST"
done

"$ROOT/tool/check_android_native.sh"
