#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/app"

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter SDK is required" >&2
  exit 1
fi

if [[ ! -d "$APP/android" ]]; then
  "$ROOT/tool/bootstrap_platforms.sh"
else
  python3 "$ROOT/tool/configure_platforms.py" --app "$APP"
fi

cd "$APP"
flutter pub get
python3 "$ROOT/tool/prepare_rhttp_android.py"
exec flutter run --no-pub -d android "$@"
