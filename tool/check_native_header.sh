#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CC_BIN="${CC:-}"
if [[ -z "$CC_BIN" ]]; then
  if command -v cc >/dev/null 2>&1; then
    CC_BIN="cc"
  elif command -v clang >/dev/null 2>&1; then
    CC_BIN="clang"
  elif command -v gcc >/dev/null 2>&1; then
    CC_BIN="gcc"
  else
    echo "SKIP: no C compiler is installed"
    exit 0
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/smoke.c" <<'C'
#include "native/media_core/include/media_core.h"

int main(void) {
  zic_byte_source *source = zic_source_create(0, 1024);
  zic_cursor *cursor = zic_cursor_create(source, 0, 8, 8);
  zic_frame *frame = 0;
  (void)zic_cursor_decode_next(cursor, 0, &frame);
  (void)zic_cursor_frame_count(cursor);
  (void)zic_cursor_loop_count(cursor);
  (void)zic_cursor_metadata_complete(cursor);
  (void)zic_cursor_cycle(cursor);
  (void)zic_cursor_rewind(cursor, 0);
  if (frame != 0) {
    zic_frame *retained = zic_frame_retain(frame);
    (void)zic_frame_epoch(frame);
    (void)zic_frame_index(frame);
    (void)zic_frame_cycle(frame);
    (void)zic_frame_width(frame);
    (void)zic_frame_height(frame);
    (void)zic_frame_duration_us(frame);
    (void)zic_frame_format(frame);
    (void)zic_frame_len(frame);
    (void)zic_frame_data(frame);
    zic_frame_release(frame);
    zic_frame_release(retained);
  }
  zic_cursor_free(cursor);
  zic_source_free(source);
  return 0;
}
C

"$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$ROOT" \
  -fsyntax-only "$TMP/smoke.c"
