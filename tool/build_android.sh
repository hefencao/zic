#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/app"
MODE="${1:-release}"
NATIVE="${ZIC_ANDROID_NATIVE:-1}"

case "$MODE" in
  debug|profile|release) ;;
  *) echo "usage: $0 [debug|profile|release]" >&2; exit 64 ;;
esac
case "$NATIVE" in
  0|1) ;;
  *) echo "ZIC_ANDROID_NATIVE must be 0 or 1" >&2; exit 64 ;;
esac

if [[ ! -d "$APP/android" ]]; then
  "$ROOT/tool/bootstrap_platforms.sh"
else
  python3 "$ROOT/tool/configure_platforms.py" --app "$APP"
fi

if [[ "$NATIVE" == 1 ]]; then
  NATIVE_MODE="$MODE"
  [[ "$NATIVE_MODE" == profile ]] && NATIVE_MODE=release
  "$ROOT/tool/build_android_native.sh" "$NATIVE_MODE"
else
  echo "ZIC_ANDROID_NATIVE=0; building split APKs without the native media core" >&2
fi

cd "$APP"
flutter build apk "--$MODE" --split-per-abi
