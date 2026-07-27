#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter SDK is required" >&2
  exit 1
fi

for rel in packages/reader apps/app; do
  echo "FLUTTER TEST: $rel/test"
  (
    cd "$ROOT/$rel"
    flutter test test "$@"
  )
done
