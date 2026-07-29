#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v dart >/dev/null 2>&1; then
  echo "Dart SDK is required" >&2
  exit 1
fi

for rel in \
  packages/domain \
  packages/resource_cache \
  packages/catalog \
  packages/downloads \
  packages/telemetry \
  packages/transport \
  packages/storage \
  packages/testkit \
  packages/pipeline \
  packages/media \
  packages/sessions \
  packages/bridge; do
  echo "DART TEST: $rel/test"
  (
    cd "$ROOT/$rel"
    dart test test "$@"
  )
done
