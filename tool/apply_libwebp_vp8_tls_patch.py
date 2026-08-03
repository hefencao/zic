#!/usr/bin/env python3
"""Apply ZIC's pinned libwebp VP8 TLS workspace patch deterministically.

The upstream file may arrive with LF or CRLF line endings depending on the
checkout/export path. GNU patch can partially apply the compact patch and then
reject the final hunk when those endings differ. This transformer anchors the
three edits to the v1.6.0 function bodies, normalizes the edited source to LF,
and is idempotent. It does not create a worker pool; it only retains one VP8
workspace per process-lifetime Dart decode isolate thread.
"""

from __future__ import annotations

import argparse
from pathlib import Path


TLS_BLOCK = """// ZIC playback decodes each animation on one of two process-lifetime Dart
// isolate threads. Keep the largest VP8 frame workspace on that OS thread so
// successive frames do not repeatedly allocate and free the same large block.
// This is deliberately a one-entry TLS cache, not an additional worker pool.
#if defined(_MSC_VER)
#define ZIC_VP8_THREAD_LOCAL __declspec(thread)
#elif defined(__GNUC__) || defined(__clang__)
#define ZIC_VP8_THREAD_LOCAL __thread
#else
#define ZIC_VP8_THREAD_LOCAL _Thread_local
#endif

typedef struct {
  uint8_t* memory;
  size_t size;
} ZicVp8ThreadBuffer;

static ZIC_VP8_THREAD_LOCAL ZicVp8ThreadBuffer
    zic_vp8_thread_buffer = { NULL, 0 };

"""

NEW_ANCHOR = """  if (dec != NULL) {
    SetOk(dec);
"""
NEW_REPLACEMENT = """  if (dec != NULL) {
    dec->mem = zic_vp8_thread_buffer.memory;
    dec->mem_size = zic_vp8_thread_buffer.size;
    zic_vp8_thread_buffer.memory = NULL;
    zic_vp8_thread_buffer.size = 0;
    SetOk(dec);
"""

CLEAR_ANCHOR = """  WebPDeallocateAlphaMemory(dec);
  WebPSafeFree(dec->mem);
  dec->mem = NULL;
"""
CLEAR_REPLACEMENT = """  WebPDeallocateAlphaMemory(dec);
  if (dec->mem != NULL && dec->mem_size >= zic_vp8_thread_buffer.size) {
    WebPSafeFree(zic_vp8_thread_buffer.memory);
    zic_vp8_thread_buffer.memory = dec->mem;
    zic_vp8_thread_buffer.size = dec->mem_size;
  } else {
    WebPSafeFree(dec->mem);
  }
  dec->mem = NULL;
"""

REQUIRED_TOKENS = (
    "ZIC_VP8_THREAD_LOCAL",
    "dec->mem = zic_vp8_thread_buffer.memory;",
    "dec->mem_size >= zic_vp8_thread_buffer.size",
)


def _replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(
            f"expected exactly one {label} anchor in pinned libwebp v1.6.0, "
            f"found {count}"
        )
    return text.replace(old, new, 1)


def apply(path: Path) -> None:
    raw = path.read_bytes()
    text = raw.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")

    present = tuple(token in text for token in REQUIRED_TOKENS)
    if all(present):
        path.write_text(text, encoding="utf-8", newline="\n")
        return
    if any(present):
        raise RuntimeError("refusing to continue from a partially applied VP8 TLS patch")

    init_anchor = "int VP8InitIoInternal(VP8Io* const io, int version) {"
    text = _replace_once(text, init_anchor, TLS_BLOCK + init_anchor, "init")

    new_start = text.find("VP8Decoder* VP8New(void) {")
    clear_start = text.find("void VP8Clear(VP8Decoder* const dec) {")
    if new_start < 0 or clear_start <= new_start:
        raise RuntimeError("pinned libwebp VP8New/VP8Clear function layout not found")
    prefix, new_body, suffix = (
        text[:new_start],
        text[new_start:clear_start],
        text[clear_start:],
    )
    new_body = _replace_once(new_body, NEW_ANCHOR, NEW_REPLACEMENT, "VP8New")
    suffix = _replace_once(suffix, CLEAR_ANCHOR, CLEAR_REPLACEMENT, "VP8Clear")
    text = prefix + new_body + suffix

    missing = [token for token in REQUIRED_TOKENS if token not in text]
    if missing:
        raise RuntimeError(f"VP8 TLS patch verification failed: missing {missing}")
    path.write_text(text, encoding="utf-8", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="path to src/dec/vp8_dec.c")
    args = parser.parse_args()
    if not args.source.is_file():
        raise SystemExit(f"missing libwebp source file: {args.source}")
    try:
        apply(args.source)
    except (OSError, UnicodeError, RuntimeError) as error:
        raise SystemExit(f"failed to apply ZIC VP8 TLS patch: {error}") from error


if __name__ == "__main__":
    main()