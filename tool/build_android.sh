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

if [[ -n "${ZIC_ANDROID_WEBP_ROOT:-}" ]]; then
  NATIVE_MODE="$MODE"
  if [[ "$NATIVE_MODE" == profile ]]; then
    NATIVE_MODE=release
  fi
  "$ROOT/tool/build_android_native.sh" "$NATIVE_MODE"
else
  echo "ZIC_ANDROID_WEBP_ROOT is not set; building APK without bundled media_core" >&2
fi

cd "$APP"
flutter build apk "--$MODE" --split-per-abi
