#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/native/libwebp.lock"
MODE="${ZIC_WEBP_HOST_MODE:-release}"
LINK="${ZIC_WEBP_HOST_LINK:-shared}"
DEPS="${ZIC_DEPS_DIR:-$ROOT/.deps}"
PREFIX="$DEPS/install/libwebp/host/$WEBP_VERSION/$MODE/$LINK"

"$ROOT/tool/build_webp_host.sh" "$MODE" >/dev/null
export ZIC_WEBP_LIB_DIR="$PREFIX/lib"
if [[ "$LINK" == static ]]; then
  export ZIC_WEBP_STATIC=1
  EXTRAS=()
  for lib in sharpyuv cpufeatures-webp; do
    [[ -e "$PREFIX/lib/lib$lib.a" ]] && EXTRAS+=("$lib")
  done
  if ((${#EXTRAS[@]})); then
    export ZIC_WEBP_EXTRA_LIBS="$(IFS=,; echo "${EXTRAS[*]}")"
  fi
  export ZIC_WEBP_SYSTEM_LIBS=m,dl
else
  unset ZIC_WEBP_STATIC || true
  unset ZIC_WEBP_EXTRA_LIBS || true
  unset ZIC_WEBP_SYSTEM_LIBS || true
  if [[ "$(uname -s)" == Darwin ]]; then
    export DYLD_LIBRARY_PATH="$PREFIX/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  else
    export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  fi
fi

cd "$ROOT"
cargo fmt --all -- --check
cargo test --workspace
