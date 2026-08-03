#!/usr/bin/env python3
"""Verify the exact ZIC VP8 TLS workspace patch on libwebp 1.6.0."""

from __future__ import annotations

import argparse
from pathlib import Path
import re


def function_body(text: str, signature: str) -> str:
    start = text.find(signature)
    if start < 0:
        raise RuntimeError(f'missing function: {signature}')
    brace = text.find('{', start)
    if brace < 0:
        raise RuntimeError(f'missing function body: {signature}')
    depth = 0
    for index in range(brace, len(text)):
        character = text[index]
        if character == '{':
            depth += 1
        elif character == '}':
            depth -= 1
            if depth == 0:
                return text[brace + 1:index]
    raise RuntimeError(f'unterminated function body: {signature}')


def require_count(text: str, token: str, count: int = 1) -> None:
    actual = text.count(token)
    if actual != count:
        raise RuntimeError(f'expected {count} occurrences of {token!r}, found {actual}')


def verify(path: Path) -> None:
    raw = path.read_bytes()
    if b'\r' in raw:
        raise RuntimeError('patched vp8_dec.c must use LF line endings')
    text = raw.decode('utf-8')
    for token in ('VP8MemPoolAcquire', 'VP8MemPoolReturn', 'WebPSetWorkerInterface'):
        if token in text:
            raise RuntimeError(f'competing playback worker/memory pool token: {token}')

    require_count(text, '#define ZIC_VP8_THREAD_LOCAL', 3)
    require_count(text, 'zic_vp8_thread_buffer = { NULL, 0 };')
    require_count(text, 'dec->mem = zic_vp8_thread_buffer.memory;')
    require_count(text, 'dec->mem_size = zic_vp8_thread_buffer.size;')
    require_count(text, 'dec->mem_size >= zic_vp8_thread_buffer.size')
    require_count(text, 'zic_vp8_thread_buffer.memory = dec->mem;')

    new_body = function_body(text, 'VP8Decoder* VP8New(void)')
    clear_body = function_body(text, 'void VP8Clear(VP8Decoder* const dec)')
    if new_body.find('dec->mem = zic_vp8_thread_buffer.memory;') > new_body.find('SetOk(dec);'):
        raise RuntimeError('VP8New must acquire the TLS workspace before decoder init')
    clear_pattern = re.compile(
        r'if \(dec->mem != NULL && dec->mem_size >= zic_vp8_thread_buffer\.size\) '
        r'\{.*?zic_vp8_thread_buffer\.memory = dec->mem;.*?\} else \{'
        r'.*?WebPSafeFree\(dec->mem\);.*?\}',
        re.DOTALL,
    )
    if clear_pattern.search(clear_body) is None:
        raise RuntimeError('VP8Clear does not return the largest workspace to TLS')
    if clear_body.find('dec->mem = NULL;') < clear_body.find(
        'zic_vp8_thread_buffer.memory = dec->mem;'
    ):
        raise RuntimeError('VP8Clear clears decoder memory before returning it to TLS')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    if not args.source.is_file():
        raise SystemExit(f'missing libwebp source file: {args.source}')
    try:
        verify(args.source)
    except (OSError, UnicodeError, RuntimeError) as error:
        raise SystemExit(f'invalid ZIC VP8 TLS patch: {error}') from error
    print('libwebp VP8 TLS patch: OK')


if __name__ == '__main__':
    main()
