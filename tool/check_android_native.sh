#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JNI="$ROOT/apps/app/android/app/src/main/jniLibs"
NOTICE="$ROOT/apps/app/android/app/src/main/assets/third_party/libwebp"
ABIS="${ZIC_ANDROID_ABIS:-arm64-v8a,armeabi-v7a,x86_64}"
LINK="${ZIC_ANDROID_WEBP_LINK:-static}"
EXPECTED_ID="$(cat "$ROOT/native/media_core/ANDROID_NATIVE_BUILD_ID")"
ACTUAL_ID="$(cat "$JNI/.zic-native-build-id" 2>/dev/null || true)"

[[ "$ACTUAL_ID" == "$EXPECTED_ID" ]] || {
  echo "stale or missing Android native build identity" >&2
  echo "expected: $EXPECTED_ID" >&2
  echo "actual:   ${ACTUAL_ID:-<missing>}" >&2
  echo "run ./tool/build_android_native.sh debug or release" >&2
  exit 1
}
for file in COPYING PATENTS SOURCE.txt; do
  [[ -s "$NOTICE/$file" ]] || {
    echo "missing packaged libwebp source notice: $NOTICE/$file" >&2
    exit 1
  }
done
if grep -q 'prebuilt' "$NOTICE/SOURCE.txt"; then
  echo "libwebp provenance must identify a source build" >&2
  exit 1
fi

READELF="${READELF:-}"
if [[ -z "$READELF" ]]; then
  for candidate in llvm-readelf readelf; do
    if command -v "$candidate" >/dev/null 2>&1; then
      READELF="$candidate"
      break
    fi
  done
fi
[[ -n "$READELF" ]] || {
  echo "llvm-readelf or readelf is required to verify JNI symbols" >&2
  exit 1
}

IFS=',' read -r -a ABI_LIST <<< "$ABIS"
for ABI in "${ABI_LIST[@]}"; do
  ABI="${ABI//[[:space:]]/}"
  DIR="$JNI/$ABI"
  LIB="$DIR/libmedia_core.so"
  [[ -s "$LIB" ]] || {
    echo "missing native media library: $LIB" >&2
    exit 1
  }
  SYMBOLS="$($READELF -Ws "$LIB")"
  for symbol in \
    Java_dev_zic_texture_NativeBlitter_prepare \
    Java_dev_zic_texture_NativeBlitter_retain \
    Java_dev_zic_texture_NativeBlitter_release \
    Java_dev_zic_texture_NativeBlitter_blit; do
    grep -q "$symbol" <<< "$SYMBOLS" || {
      echo "missing JNI symbol $symbol in $LIB" >&2
      exit 1
    }
  done
  for symbol in \
    zic_cursor_known_frame_count \
    zic_cursor_full_canvas_frame_count \
    zic_cursor_independent_frame_count \
    zic_cursor_max_dependent_run \
    zic_frame_native_prepare_us \
    zic_frame_native_canvas_prepare_us \
    zic_frame_native_fragment_decode_us \
    zic_frame_native_composite_us \
    zic_frame_native_frame_copy_us \
    zic_frame_native_thread_id \
    zic_frame_native_cpu_start \
    zic_frame_native_cpu_end \
    zic_frame_native_cpu_allowed_mask; do
    grep -q "$symbol" <<< "$SYMBOLS" || {
      echo "missing native diagnostic symbol $symbol in $LIB" >&2
      exit 1
    }
  done
  if grep -q 'Java_dev_zic_texture_NativeBlitter_configure' <<< "$SYMBOLS"; then
    echo "obsolete standalone texture configure JNI symbol remains in $LIB" >&2
    exit 1
  fi
  if [[ "$LINK" == shared ]]; then
    [[ -s "$DIR/libwebp.so" ]] || {
      echo "missing source-built libwebp dependency: $DIR/libwebp.so" >&2
      exit 1
    }
    [[ -s "$DIR/libwebpdemux.so" ]] || {
      echo "missing source-built libwebpdemux dependency: $DIR/libwebpdemux.so" >&2
      exit 1
    }
  fi
done
printf 'Android source-built native layout: OK (%s, %s)\n' "$ABIS" "$EXPECTED_ID"
