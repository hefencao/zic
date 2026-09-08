#!/usr/bin/env python3
from pathlib import Path

PATH = Path('apps/app/android/app/src/main/kotlin/dev/zic/zic/MainActivity.kt')
TEXT = PATH.read_text()


def function_body(name: str) -> str:
    marker = f'private fun {name}('
    start = TEXT.find(marker)
    if start < 0:
        raise SystemExit(f'{name} not found')
    brace = TEXT.find('{', start)
    if brace < 0:
        raise SystemExit(f'{name} body not found')
    depth = 0
    for i in range(brace, len(TEXT)):
        c = TEXT[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return TEXT[brace:i + 1]
    raise SystemExit(f'{name} body is unterminated')

for name in ('safOpen', 'safDelete', 'safRename', 'safReplace'):
    body = function_body(name)
    if 'clearSafPathCache(treeUri)' in body:
        raise SystemExit(f'{name} must not invalidate the entire SAF tree cache')

read_body = function_body('openSafReadDescriptor')
if 'invalidateSafReadParentListing(treeUri, relativePath)' not in read_body:
    raise SystemExit('stale exact SAF reads must invalidate the target parent first')
if read_body.count('clearSafPathCache(treeUri)') != 1:
    raise SystemExit('SAF read recovery must keep exactly one full-tree final fallback')

for name in ('safDelete', 'safRename', 'safReplace'):
    if 'invalidateSafDirectoryListing' not in function_body(name):
        raise SystemExit(f'{name} must invalidate affected directory listings')

if 'invalidateSafDirectoryListing(treeUri, parent)' not in function_body('safOpen'):
    raise SystemExit('SAF create must invalidate each mutated parent directory')

print('SAF path cache invalidation scope: OK')
