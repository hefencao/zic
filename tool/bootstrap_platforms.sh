#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/app"

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter SDK is required" >&2
  exit 1
fi

cd "$APP"
flutter create \
  --project-name zic \
  --org dev.zic \
  --platforms android,ios \
  .

echo "Platform scaffolding generated in $APP"
