#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/native/libwebp.lock"
DEPS="${ZIC_DEPS_DIR:-$ROOT/.deps}"
PINNED="$DEPS/src/libwebp-$WEBP_VERSION"
SOURCE="${ZIC_WEBP_SOURCE:-$PINNED}"

validate_tree() {
  local dir="$1"
  for required in CMakeLists.txt configure.ac COPYING PATENTS src/webp/decode.h src/webp/demux.h; do
    [[ -f "$dir/$required" ]] || {
      echo "invalid libwebp source tree, missing: $dir/$required" >&2
      exit 1
    }
  done
}

if [[ -n "${ZIC_WEBP_SOURCE:-}" ]]; then
  SOURCE="$(cd "$SOURCE" && pwd)"
  validate_tree "$SOURCE"
  if [[ -d "$SOURCE/.git" ]]; then
    HEAD="$(git -C "$SOURCE" rev-parse HEAD)"
    if [[ "$HEAD" != "$WEBP_COMMIT" && "${ZIC_WEBP_ALLOW_UNPINNED:-0}" != 1 ]]; then
      echo "libwebp source commit $HEAD does not match pinned $WEBP_COMMIT" >&2
      echo "set ZIC_WEBP_ALLOW_UNPINNED=1 only for deliberate local development" >&2
      exit 1
    fi
  elif [[ "${ZIC_WEBP_ALLOW_UNPINNED:-0}" != 1 ]]; then
    echo "ZIC_WEBP_SOURCE is not a git checkout; exact source revision cannot be verified" >&2
    echo "set ZIC_WEBP_ALLOW_UNPINNED=1 only for a trusted extracted source tree" >&2
    exit 1
  fi
  printf '%s\n' "$SOURCE"
  exit 0
fi

for command in git; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required to fetch pinned libwebp source" >&2
    exit 1
  }
done

if [[ -d "$SOURCE/.git" ]]; then
  HEAD="$(git -C "$SOURCE" rev-parse HEAD)"
  if [[ "$HEAD" != "$WEBP_COMMIT" ]]; then
    echo "cached libwebp checkout is at $HEAD, expected $WEBP_COMMIT" >&2
    echo "remove $SOURCE or set ZIC_DEPS_DIR to a clean dependency cache" >&2
    exit 1
  fi
  validate_tree "$SOURCE"
  printf '%s\n' "$SOURCE"
  exit 0
fi

if [[ -e "$SOURCE" ]]; then
  echo "dependency path exists but is not the pinned git checkout: $SOURCE" >&2
  exit 1
fi

mkdir -p "$(dirname "$SOURCE")"
TMP="$SOURCE.tmp.$$"
trap 'rm -rf "$TMP"' EXIT

echo "Fetching libwebp $WEBP_VERSION at $WEBP_COMMIT from $WEBP_REPO" >&2
git init -q "$TMP"
git -C "$TMP" remote add origin "$WEBP_REPO"
git -C "$TMP" fetch -q --depth=1 origin "$WEBP_COMMIT"
git -C "$TMP" checkout -q --detach FETCH_HEAD
HEAD="$(git -C "$TMP" rev-parse HEAD)"
[[ "$HEAD" == "$WEBP_COMMIT" ]] || {
  echo "fetched libwebp commit $HEAD does not match pinned $WEBP_COMMIT" >&2
  exit 1
}
validate_tree "$TMP"
mv "$TMP" "$SOURCE"
trap - EXIT
printf '%s\n' "$SOURCE"
