#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/native/media_core/testdata"
DST="$ROOT/apps/app/assets/demo/animated"

mkdir -p "$DST"
for name in animated.webp finite_loop.webp partial_blend.webp; do
  cp "$SRC/$name" "$DST/$name"
done

echo "demo Animated WebP assets synchronized"
