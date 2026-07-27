#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/app"
MODE="${1:-release}"

case "$MODE" in
  debug|profile|release) ;;
  *)
    echo "usage: $0 [debug|profile|release]" >&2
    exit 64
    ;;
esac

if [[ ! -d "$APP/android" ]]; then
  "$ROOT/tool/bootstrap_platforms.sh"
fi

cd "$APP"
flutter build apk "--$MODE" --split-per-abi
