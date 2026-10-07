#!/usr/bin/env python3
"""Ownership gate for dev.293 vertical media aspect independence."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.293 tokens: {missing}')

def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains superseded dev.293 tokens: {found}')

require(
    'packages/local_media_ui/lib/src/local_image_player.dart',
    'Presentation must never inherit a transient aspect error',
    "fit == BoxFit.fitWidth ? Alignment.topCenter : Alignment.center",
    'child: FittedBox(',
    'fit: fit,',
    'child: builder(BoxFit.fill)',
)
forbid(
    'packages/local_media_ui/lib/src/local_image_player.dart',
    'ReaderVerticalGeometry already owns the exact',
)
require(
    'packages/local_media_ui/test/media_aspect_viewport_test.dart',
    'continuous fitWidth preserves source aspect across a transient parent extent',
    'expect(fitted.fit, BoxFit.fitWidth);',
    'expect(fitted.alignment, Alignment.topCenter);',
    'expect(sourceBox.width, 100);',
    'expect(sourceBox.height, 400);',
)
require(
    'packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
    'forwardEncodedPages: 7',
    'backwardEncodedPages: 3',
    'forwardDecodePages: 2',
    'backwardDecodePages: 1',
)
require(
    'docs/archive/adr/0272-vertical-media-aspect-independence.md',
    'BoxFit.fill',
    'top-aligned `FittedBox(fitWidth)`',
    '不恢复 dev.286',
)
print('dev.293 vertical media aspect boundary: OK')
