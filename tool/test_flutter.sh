#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter SDK is required" >&2
  exit 1
fi

for rel in packages/reader packages/plugin_host_bridge packages/texture_bridge packages/local_media_bridge packages/local_media packages/runtime_bridge packages/storage_bridge packages/downloads_bridge apps/app; do
  echo "FLUTTER TEST: $rel/test"
  (
    cd "$ROOT/$rel"
    flutter test test "$@"
  )
done
