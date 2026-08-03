#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/native/libwebp.lock"
DEPS="${ZIC_DEPS_DIR:-$ROOT/.deps}"
PATCH_FILE="$ROOT/native/patches/libwebp-vp8-thread-buffer-pool-v1.6.0.patch"
VERIFY="$ROOT/tool/verify_libwebp_vp8_tls_patch.py"

for command in patch python3 sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required to prepare patched libwebp" >&2
    exit 1
  }
done
for required in "$PATCH_FILE" "$VERIFY"; do
  [[ -f "$required" ]] || {
    echo "missing pinned libwebp preparation input: $required" >&2
    exit 1
  }
done

SOURCE="$("$ROOT/tool/fetch_webp.sh")"
SOURCE_SHA="$(sha256sum "$SOURCE/src/dec/vp8_dec.c" | awk '{print $1}')"
[[ "$SOURCE_SHA" == "$WEBP_VP8_DEC_SHA256" ]] || {
  echo "refusing to patch a modified libwebp source tree: $SOURCE" >&2
  echo "actual=$SOURCE_SHA expected=$WEBP_VP8_DEC_SHA256" >&2
  exit 1
}
PATCH_SHA="$(sha256sum "$PATCH_FILE" | awk '{print $1}')"
PREPARED="$DEPS/src/prepared/libwebp-$WEBP_VERSION-zic-${SOURCE_SHA:0:8}-${PATCH_SHA:0:8}"
MARKER="$PREPARED/.zic-libwebp-patch"
EXPECTED="$WEBP_COMMIT|$SOURCE_SHA|$PATCH_SHA"

if [[ -f "$MARKER" && "$(cat "$MARKER")" == "$EXPECTED" ]]; then
  python3 "$VERIFY" "$PREPARED/src/dec/vp8_dec.c" >/dev/null
  printf '%s\n' "$PREPARED"
  exit 0
fi

if [[ -e "$PREPARED" ]]; then
  echo "rebuilding stale prepared libwebp tree: $PREPARED" >&2
  rm -rf "$PREPARED"
fi
mkdir -p "$(dirname "$PREPARED")"
TMP="$PREPARED.tmp.$$"
PATCH_LOG="$TMP.patch.log"
trap 'rm -rf "$TMP" "$PATCH_LOG"' EXIT
mkdir -p "$TMP"
cp -a "$SOURCE/." "$TMP/"
rm -rf "$TMP/.git" "$TMP/.zic-libwebp-upstream"
python3 - "$TMP/src/dec/vp8_dec.c" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_bytes(path.read_bytes().replace(b'\r\n', b'\n').replace(b'\r', b'\n'))
PY

if ! patch --dry-run --batch --forward --fuzz=0 -d "$TMP" -p1 \
    < "$PATCH_FILE" >"$PATCH_LOG" 2>&1; then
  cat "$PATCH_LOG" >&2
  echo "pinned libwebp patch dry-run failed before any source was modified" >&2
  exit 1
fi
patch --batch --forward --fuzz=0 -d "$TMP" -p1 < "$PATCH_FILE" \
  >>"$PATCH_LOG" 2>&1
python3 "$VERIFY" "$TMP/src/dec/vp8_dec.c" >/dev/null
find "$TMP" -name '*.rej' -o -name '*.orig' | grep -q . && {
  echo "libwebp preparation left reject/original files" >&2
  exit 1
}
printf '%s' "$EXPECTED" > "$TMP/.zic-libwebp-patch"
mv "$TMP" "$PREPARED"
rm -f "$PATCH_LOG"
trap - EXIT
printf '%s\n' "$PREPARED"
