#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/native/media_core/testdata/animated.webp"
BLEND_FIXTURE="$ROOT/native/media_core/testdata/partial_blend.webp"
FINITE_FIXTURE="$ROOT/native/media_core/testdata/finite_loop.webp"
SOURCE="$ROOT/tools/webp_decoder_smoke.c"
BINARY="$(mktemp -t zic-webp-smoke.XXXXXX)"
trap 'rm -f "$BINARY"' EXIT

if ! command -v pkg-config >/dev/null 2>&1 || \
   ! pkg-config --exists libwebp libwebpdemux; then
  echo "libwebp and libwebpdemux development packages are required" >&2
  exit 1
fi

CC_BIN="${CC:-cc}"
"$CC_BIN" -std=c11 -Wall -Wextra -Werror \
  "$SOURCE" -o "$BINARY" \
  $(pkg-config --cflags --libs libwebp libwebpdemux)
"$BINARY" "$FIXTURE" "$BLEND_FIXTURE" "$FINITE_FIXTURE"
