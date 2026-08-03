#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/native/libwebp.lock"
DEPS="${ZIC_DEPS_DIR:-$ROOT/.deps}"
PATCH_FILE="$ROOT/native/patches/libwebp-vp8-thread-buffer-pool-v1.6.0.patch"
PATCH_APPLIER="$ROOT/tool/apply_libwebp_vp8_tls_patch.py"

for command in python3 sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required to prepare patched libwebp" >&2
    exit 1
  }
done
[[ -f "$PATCH_FILE" ]] || {
  echo "missing pinned libwebp patch: $PATCH_FILE" >&2
  exit 1
}
[[ -f "$PATCH_APPLIER" ]] || {
  echo "missing pinned libwebp patch applier: $PATCH_APPLIER" >&2
  exit 1
}

SOURCE="$("$ROOT/tool/fetch_webp.sh")"
PATCH_SHA="$(sha256sum "$PATCH_FILE" | awk '{print $1}')"
APPLIER_SHA="$(sha256sum "$PATCH_APPLIER" | awk '{print $1}')"
PREPARED="$DEPS/src/libwebp-$WEBP_VERSION-zic-${PATCH_SHA:0:8}-${APPLIER_SHA:0:8}"
MARKER="$PREPARED/.zic-libwebp-patch"
EXPECTED="$WEBP_COMMIT|$PATCH_SHA|$APPLIER_SHA"

if [[ -f "$MARKER" && "$(cat "$MARKER")" == "$EXPECTED" ]]; then
  grep -q 'zic_vp8_thread_buffer' "$PREPARED/src/dec/vp8_dec.c" || {
    echo "prepared libwebp marker exists but patch token is missing" >&2
    exit 1
  }
  printf '%s\n' "$PREPARED"
  exit 0
fi

if [[ -e "$PREPARED" ]]; then
  echo "prepared dependency path is stale: $PREPARED" >&2
  echo "remove it or use a clean ZIC_DEPS_DIR" >&2
  exit 1
fi

mkdir -p "$(dirname "$PREPARED")"
TMP="$PREPARED.tmp.$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP"
cp -a "$SOURCE/." "$TMP/"
rm -rf "$TMP/.git"
python3 "$PATCH_APPLIER" \
  "$TMP/src/dec/vp8_dec.c"
grep -q 'zic_vp8_thread_buffer' "$TMP/src/dec/vp8_dec.c" || {
  echo "libwebp patch applied without expected TLS buffer token" >&2
  exit 1
}
printf '%s' "$EXPECTED" > "$TMP/.zic-libwebp-patch"
mv "$TMP" "$PREPARED"
trap - EXIT
printf '%s\n' "$PREPARED"
