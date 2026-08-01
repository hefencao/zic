#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v dart >/dev/null 2>&1 || ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter and Dart SDKs are required" >&2
  exit 1
fi

for rel in \
  packages/domain \
  packages/resource_cache \
  packages/catalog \
  packages/plugin_host \
  packages/downloads \
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

for rel in \
  packages/reader \
  packages/pipeline_runtime \
  packages/pipeline_native \
  packages/reader_runtime \
  packages/plugin_host_bridge \
  packages/texture_bridge \
  packages/local_media_bridge \
  packages/local_media \
  packages/local_media_ui \
  packages/runtime_bridge \
  packages/storage_bridge \
  packages/downloads_bridge \
  apps/app; do
  echo "FLUTTER ANALYZE: $rel"
  (cd "$ROOT/$rel" && flutter analyze)
done
