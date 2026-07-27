#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JNI="$ROOT/apps/app/android/app/src/main/jniLibs"
NOTICE="$ROOT/apps/app/android/app/src/main/assets/third_party/libwebp"
ABIS="${ZIC_ANDROID_ABIS:-arm64-v8a,armeabi-v7a,x86_64}"
LINK="${ZIC_ANDROID_WEBP_LINK:-static}"

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

IFS=',' read -r -a ABI_LIST <<< "$ABIS"
for ABI in "${ABI_LIST[@]}"; do
  ABI="${ABI//[[:space:]]/}"
  DIR="$JNI/$ABI"
  [[ -s "$DIR/libmedia_core.so" ]] || {
    echo "missing native media library: $DIR/libmedia_core.so" >&2
    exit 1
  }
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
printf 'Android source-built native layout: OK (%s)\n' "$ABIS"
