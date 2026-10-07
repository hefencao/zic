#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/tool/reader_surfaceflinger_perfetto.pbtxt"
OUTPUT="${1:-zic-reader-surfaceflinger.perfetto-trace}"
DURATION_MS="${ZIC_PERFETTO_DURATION_MS:-20000}"
REMOTE="/data/misc/perfetto-traces/zic-reader-surfaceflinger.perfetto-trace"

if ! command -v adb >/dev/null 2>&1; then
  echo "adb is required" >&2
  exit 2
fi

SDK="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
case "$SDK" in
  ''|*[!0-9]*)
    echo "could not determine Android SDK level: $SDK" >&2
    exit 2
    ;;
esac
if (( SDK < 31 )); then
  echo "Android API 31+ is required for SurfaceFlinger FrameTimeline; device reports API $SDK" >&2
  exit 2
fi
if [[ ! "$DURATION_MS" =~ ^[0-9]+$ ]] || (( DURATION_MS < 5000 )); then
  echo "ZIC_PERFETTO_DURATION_MS must be an integer >= 5000" >&2
  exit 2
fi

mkdir -p "$(dirname "$OUTPUT")"
TMP_OUTPUT=""
cleanup() {
  if [[ -n "$TMP_OUTPUT" ]]; then
    rm -f "$TMP_OUTPUT"
  fi
  adb shell rm -f "$REMOTE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

adb shell rm -f "$REMOTE" >/dev/null 2>&1 || true
printf 'Capturing %sms on Android API %s. Reproduce the fixed-position Reader hitch now.\n' "$DURATION_MS" "$SDK"
sed "s/^duration_ms: .*/duration_ms: $DURATION_MS/" "$CONFIG" |
  adb shell perfetto --txt -c - -o "$REMOTE"
TMP_OUTPUT="$(mktemp "${OUTPUT}.XXXXXX")"
adb pull "$REMOTE" "$TMP_OUTPUT" >/dev/null
mv -f "$TMP_OUTPUT" "$OUTPUT"
TMP_OUTPUT=""
printf 'Wrote %s\n' "$OUTPUT"
