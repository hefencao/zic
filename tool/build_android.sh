#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/app"
MODE="${1:-release}"
NATIVE="${ZIC_ANDROID_NATIVE:-1}"
RHTTP_RECEIVE_DIAGNOSTICS="${ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS:-0}"
READER_CADENCE_DIAGNOSTICS="${ZIC_READER_FRAME_CADENCE_DIAGNOSTICS:-0}"

case "$MODE" in
  debug|profile|release) ;;
  *) echo "usage: $0 [debug|profile|release]" >&2; exit 64 ;;
esac
case "$NATIVE" in
  0|1) ;;
  *) echo "ZIC_ANDROID_NATIVE must be 0 or 1" >&2; exit 64 ;;
esac
case "$RHTTP_RECEIVE_DIAGNOSTICS" in
  0|1) ;;
  *) echo "ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS must be 0 or 1" >&2; exit 64 ;;
esac

case "$READER_CADENCE_DIAGNOSTICS" in
  0|1) ;;
  *) echo "ZIC_READER_FRAME_CADENCE_DIAGNOSTICS must be 0 or 1" >&2; exit 64 ;;
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
  echo "ZIC_ANDROID_NATIVE=0; reusing staged native libraries for split APKs" >&2
fi

cd "$APP"
flutter pub get
python3 "$ROOT/tool/prepare_rhttp_android.py"
python3 "$ROOT/tool/prepare_translation_android.py"
FLUTTER_ARGS=("--$MODE" --split-per-abi)
if [[ "$RHTTP_RECEIVE_DIAGNOSTICS" == 1 ]]; then
  FLUTTER_ARGS+=(--dart-define=ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS=true)
fi
if [[ "$READER_CADENCE_DIAGNOSTICS" == 1 ]]; then
  FLUTTER_ARGS+=(--dart-define=ZIC_READER_FRAME_CADENCE_DIAGNOSTICS=true)
fi
flutter build apk --no-pub "${FLUTTER_ARGS[@]}"
# This command produces split APKs. Remove only its obsolete universal output
# so a previous direct Flutter build cannot be mistaken for the current result.
rm -f -- "$APP/build/app/outputs/flutter-apk/app-$MODE.apk"
python3 - "$APP/build/app/outputs/flutter-apk" "$MODE" <<'PY'
from pathlib import Path
import sys
for abi in ('arm64-v8a', 'armeabi-v7a', 'x86_64'):
    apk = Path(sys.argv[1]) / f'app-{abi}-{sys.argv[2]}.apk'
    print(f'{apk}: {apk.stat().st_size / 1048576:.2f} MiB')
PY
