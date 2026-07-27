#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JNI="$ROOT/apps/app/android/app/src/main/jniLibs"
ABIS="${ZIC_ANDROID_ABIS:-arm64-v8a,armeabi-v7a,x86_64}"
LINK="${ZIC_ANDROID_WEBP_LINK:-shared}"

IFS=',' read -r -a ABI_LIST <<< "$ABIS"
for ABI in "${ABI_LIST[@]}"; do
  DIR="$JNI/$ABI"
  [[ -s "$DIR/libmedia_core.so" ]] || {
    echo "missing native media library: $DIR/libmedia_core.so" >&2
    exit 1
  }
  if [[ "$LINK" == shared ]]; then
    [[ -s "$DIR/libwebp.so" ]] || {
      echo "missing libwebp dependency: $DIR/libwebp.so" >&2
      exit 1
    }
    [[ -s "$DIR/libwebpdemux.so" ]] || {
      echo "missing libwebpdemux dependency: $DIR/libwebpdemux.so" >&2
      exit 1
    }
  fi
done
printf 'Android native layout: OK (%s)\n' "$ABIS"
