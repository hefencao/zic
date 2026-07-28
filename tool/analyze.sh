#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v dart >/dev/null 2>&1 || ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter and Dart SDKs are required" >&2
  exit 1
fi

for rel in \
  packages/domain \
  packages/catalog \
  packages/telemetry \
  packages/transport \
  packages/storage \
  packages/testkit \
  packages/pipeline \
  packages/media \
  packages/sessions \
  packages/bridge; do
  echo "DART ANALYZE: $rel"
  (cd "$ROOT/$rel" && dart analyze)
done

for rel in packages/reader packages/texture_bridge packages/local_media_bridge packages/local_media apps/app; do
  echo "FLUTTER ANALYZE: $rel"
  (cd "$ROOT/$rel" && flutter analyze)
done
