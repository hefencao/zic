#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/native/libwebp.lock"
MODE="${ZIC_WEBP_HOST_MODE:-release}"
LINK="${ZIC_WEBP_HOST_LINK:-shared}"
if [[ ! -w "$ROOT" ]] || [[ -e "$ROOT/.deps" && ! -w "$ROOT/.deps" ]]; then
  export ZIC_DEPS_DIR="${ZIC_DEPS_DIR:-/tmp/zic-deps}"
fi
DEPS="${ZIC_DEPS_DIR:-$ROOT/.deps}"
PREFIX="$DEPS/install/libwebp/host/$WEBP_VERSION/$MODE/$LINK"
FIXTURE="$ROOT/native/media_core/testdata/animated.webp"
BLEND_FIXTURE="$ROOT/native/media_core/testdata/partial_blend.webp"
FINITE_FIXTURE="$ROOT/native/media_core/testdata/finite_loop.webp"
SOURCE="$ROOT/tools/webp_decoder_smoke.c"
BINARY="$(mktemp -t zic-webp-smoke.XXXXXX)"
trap 'rm -f "$BINARY"' EXIT

"$ROOT/tool/build_webp_host.sh" "$MODE" >/dev/null
CC_BIN="${CC:-cc}"
LDFLAGS=(-L"$PREFIX/lib" -lwebpdemux -lwebp)
if [[ "$LINK" == shared ]]; then
  case "$(uname -s)" in
    Darwin) LDFLAGS=(-L"$PREFIX/lib" -Wl,-rpath,"$PREFIX/lib" -lwebpdemux -lwebp) ;;
    *) LDFLAGS=(-L"$PREFIX/lib" -Wl,-rpath,"$PREFIX/lib" -lwebpdemux -lwebp) ;;
  esac
fi
"$CC_BIN" -std=c11 -Wall -Wextra -Werror \
  -I"$PREFIX/include" "$SOURCE" -o "$BINARY" "${LDFLAGS[@]}"
"$BINARY" "$FIXTURE" "$BLEND_FIXTURE" "$FINITE_FIXTURE"
