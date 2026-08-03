#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/native/libwebp.lock"
DEPS="${ZIC_DEPS_DIR:-$ROOT/.deps}"
PATCH_FILE="$ROOT/native/patches/libwebp-vp8-thread-buffer-pool-v1.6.0.patch"

for command in patch sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required to prepare patched libwebp" >&2
    exit 1
  }
done
[[ -f "$PATCH_FILE" ]] || {
  echo "missing pinned libwebp patch: $PATCH_FILE" >&2
  exit 1
}

SOURCE="$("$ROOT/tool/fetch_webp.sh")"
PATCH_SHA="$(sha256sum "$PATCH_FILE" | awk '{print $1}')"
PREPARED="$DEPS/src/libwebp-$WEBP_VERSION-zic-${PATCH_SHA:0:16}"
MARKER="$PREPARED/.zic-libwebp-patch"
EXPECTED="$WEBP_COMMIT|$PATCH_SHA"

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
python3 - "$TMP/src/dec/vp8_dec.c" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
if path.exists():
    data = path.read_bytes().replace(b'\r\n', b'\n').replace(b'\r', b'\n')
    path.write_bytes(data)
PY
if ! patch --batch --forward --binary -d "$TMP" -p1 < "$PATCH_FILE"; then
  if grep -Eq 'zic_vp8_thread_buffer|VP8MemPoolReturn|VP8MemPoolAcquire' "$TMP/src/dec/vp8_dec.c"; then
    echo "libwebp source already contains an equivalent VP8 mem-pool patch" >&2
  else
    echo "libwebp patch failed and no equivalent patch implementation was found" >&2
    exit 1
  fi
fi
grep -Eq 'zic_vp8_thread_buffer|VP8MemPoolReturn|VP8MemPoolAcquire' "$TMP/src/dec/vp8_dec.c" || {
  echo "libwebp patch applied without expected TLS buffer token" >&2
  exit 1
}
printf '%s' "$EXPECTED" > "$TMP/.zic-libwebp-patch"
mv "$TMP" "$PREPARED"
trap - EXIT
printf '%s\n' "$PREPARED"
