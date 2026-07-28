#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/app"

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter SDK is required" >&2
  exit 1
fi

printf 'Flutter app directory: %s\n' "$APP"
printf '%s\n' 'Running: flutter create --empty --project-name zic --org dev.zic --platforms=android,ios .'

cd "$APP"
flutter create \
  --empty \
  --project-name zic \
  --org dev.zic \
  --platforms=android,ios \
  .

python3 "$ROOT/tool/configure_platforms.py" --app "$APP"

printf 'Platform scaffolding generated and configured in %s\n' "$APP"
printf '%s\n' 'Run app tests from apps/app: flutter test test'
printf '%s\n' 'Run reader tests from packages/reader: flutter test test'
