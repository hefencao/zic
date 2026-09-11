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
  (void)zic_abi_version();
  (void)zic_version();
  (void)zic_webp_decoder_version();
  (void)zic_webp_demux_version();
  zic_byte_source *source = zic_source_create(0, 1024);
  uint8_t *reserved = 0;
  (void)zic_source_reserve_capacity(source, 0, 512);
  (void)zic_source_reserve(source, 0, 0, 4, &reserved);
  if (reserved != 0) {
    reserved[0] = 'R';
    reserved[1] = 'I';
    reserved[2] = 'F';
    reserved[3] = 'F';
    (void)zic_source_commit(source, 0, 0, 4);
  }
  zic_cursor *cursor = zic_cursor_create(source, 0, 8, 8);
  zic_frame *frame = 0;
  (void)zic_cursor_decode_next(cursor, 0, &frame);
  (void)zic_cursor_frame_count(cursor);
  (void)zic_cursor_loop_count(cursor);
  (void)zic_cursor_metadata_complete(cursor);
  (void)zic_cursor_cycle(cursor);
  (void)zic_cursor_known_frame_count(cursor);
  (void)zic_cursor_full_canvas_frame_count(cursor);
  (void)zic_cursor_independent_frame_count(cursor);
  (void)zic_cursor_max_dependent_run(cursor);
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
    (void)zic_frame_native_prepare_us(frame);
    (void)zic_frame_native_canvas_prepare_us(frame);
    (void)zic_frame_native_fragment_decode_us(frame);
    (void)zic_frame_native_composite_us(frame);
    (void)zic_frame_native_frame_copy_us(frame);
    (void)zic_frame_native_thread_id(frame);
    (void)zic_frame_native_cpu_start(frame);
    (void)zic_frame_native_cpu_end(frame);
    (void)zic_frame_native_cpu_allowed_mask(frame);
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
