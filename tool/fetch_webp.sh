#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/native/libwebp.lock"
DEPS="${ZIC_DEPS_DIR:-$ROOT/.deps}"
ALLOW_UNPINNED="${ZIC_WEBP_ALLOW_UNPINNED:-0}"

for command in python3 sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required to verify/extract pinned libwebp source" >&2
    exit 1
  }
done

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

validate_tree() {
  local dir="$1"
  for required in \
    CMakeLists.txt configure.ac COPYING PATENTS \
    src/webp/decode.h src/webp/demux.h src/dec/vp8_dec.c; do
    [[ -f "$dir/$required" ]] || {
      echo "invalid libwebp source tree, missing: $dir/$required" >&2
      return 1
    }
  done
}

validate_clean_revision() {
  local dir="$1"
  validate_tree "$dir"
  local actual
  actual="$(sha256_file "$dir/src/dec/vp8_dec.c")"
  if [[ "$actual" != "$WEBP_VP8_DEC_SHA256" ]]; then
    if [[ "$ALLOW_UNPINNED" == 1 ]]; then
      echo "warning: accepting modified/unpinned libwebp source: $dir" >&2
      echo "warning: vp8_dec sha256=$actual expected=$WEBP_VP8_DEC_SHA256" >&2
      return 0
    fi
    echo "libwebp source is not the clean pinned v$WEBP_VERSION tree: $dir" >&2
    echo "vp8_dec sha256=$actual expected=$WEBP_VP8_DEC_SHA256" >&2
    echo "use the retained $WEBP_ARCHIVE_PATH archive or a clean pinned checkout" >&2
    return 1
  fi
  if [[ -d "$dir/.git" ]]; then
    local head
    head="$(git -C "$dir" rev-parse HEAD)"
    if [[ "$head" != "$WEBP_COMMIT" && "$ALLOW_UNPINNED" != 1 ]]; then
      echo "libwebp source commit $head does not match pinned $WEBP_COMMIT" >&2
      return 1
    fi
  fi
}

extract_archive() {
  local archive="$1"
  local archive_sha="$2"
  local destination="$3"
  local marker="$destination/.zic-libwebp-upstream"
  local expected="archive|$archive_sha|$WEBP_VP8_DEC_SHA256"

  if [[ -f "$marker" && "$(cat "$marker")" == "$expected" ]]; then
    if validate_clean_revision "$destination"; then
      printf '%s\n' "$destination"
      return 0
    fi
    echo "rebuilding corrupted libwebp upstream cache: $destination" >&2
  fi

  rm -rf "$destination"
  mkdir -p "$(dirname "$destination")"
  local temporary="$destination.tmp.$$"
  trap 'rm -rf "$temporary"' RETURN
  mkdir -p "$temporary"
  python3 - "$archive" "$temporary" <<'PY'
from pathlib import Path, PurePosixPath
from zipfile import ZipFile
import sys

archive = Path(sys.argv[1])
destination = Path(sys.argv[2]).resolve()
with ZipFile(archive) as source:
    for entry in source.infolist():
        path = PurePosixPath(entry.filename)
        if path.is_absolute() or '..' in path.parts:
            raise SystemExit(f'unsafe path in libwebp archive: {entry.filename}')
    source.extractall(destination)
PY

  local source_root
  source_root="$(find "$temporary" -mindepth 1 -maxdepth 3 -type f \
    -name CMakeLists.txt -printf '%h\n' | while IFS= read -r candidate; do
      [[ -f "$candidate/src/dec/vp8_dec.c" && -f "$candidate/src/webp/decode.h" ]] && \
        printf '%s\n' "$candidate"
    done)"
  if [[ -z "$source_root" || "$source_root" == *$'\n'* ]]; then
    echo "libwebp archive must contain exactly one source root" >&2
    return 1
  fi
  validate_clean_revision "$source_root"
  printf '%s' "$expected" > "$source_root/.zic-libwebp-upstream"
  mv "$source_root" "$destination"
  rm -rf "$temporary"
  trap - RETURN
  printf '%s\n' "$destination"
}

if [[ -n "${ZIC_WEBP_SOURCE:-}" ]]; then
  SOURCE="$(cd "$ZIC_WEBP_SOURCE" && pwd)"
  validate_clean_revision "$SOURCE"
  printf '%s\n' "$SOURCE"
  exit 0
fi

ARCHIVE="${ZIC_WEBP_ARCHIVE:-$ROOT/$WEBP_ARCHIVE_PATH}"
if [[ -f "$ARCHIVE" ]]; then
  ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"
  ACTUAL_ARCHIVE_SHA="$(sha256_file "$ARCHIVE")"
  if [[ "$ACTUAL_ARCHIVE_SHA" != "$WEBP_ARCHIVE_SHA256" && "$ALLOW_UNPINNED" != 1 ]]; then
    echo "libwebp archive sha256 mismatch: $ARCHIVE" >&2
    echo "actual=$ACTUAL_ARCHIVE_SHA expected=$WEBP_ARCHIVE_SHA256" >&2
    exit 1
  fi
  DESTINATION="$DEPS/src/upstream/libwebp-$WEBP_VERSION-archive-${ACTUAL_ARCHIVE_SHA:0:16}"
  extract_archive "$ARCHIVE" "$ACTUAL_ARCHIVE_SHA" "$DESTINATION"
  exit 0
fi

command -v git >/dev/null 2>&1 || {
  echo "git is required only when the retained libwebp archive is unavailable" >&2
  exit 1
}
SOURCE="$DEPS/src/upstream/libwebp-$WEBP_VERSION-git-${WEBP_COMMIT:0:16}"
if [[ -d "$SOURCE/.git" ]] && validate_clean_revision "$SOURCE"; then
  printf '%s\n' "$SOURCE"
  exit 0
fi
rm -rf "$SOURCE"
mkdir -p "$(dirname "$SOURCE")"
TMP="$SOURCE.tmp.$$"
trap 'rm -rf "$TMP"' EXIT

echo "retained libwebp archive unavailable; fetching $WEBP_COMMIT" >&2
git init -q "$TMP"
git -C "$TMP" remote add origin "$WEBP_REPO"
git -C "$TMP" fetch -q --depth=1 origin "$WEBP_COMMIT"
git -C "$TMP" checkout -q --detach FETCH_HEAD
validate_clean_revision "$TMP"
mv "$TMP" "$SOURCE"
trap - EXIT
printf '%s\n' "$SOURCE"
