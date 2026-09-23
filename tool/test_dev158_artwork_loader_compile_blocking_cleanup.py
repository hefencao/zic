#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [t for t in tokens if t not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.158 tokens: {missing}')

def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [t for t in tokens if t in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains superseded dev.158 tokens: {found}')

require('packages/storage_bridge/lib/storage_bridge.dart', "import 'dart:typed_data';", 'Future<Uint8List> readEncodedResourceBytes')
require(
    'apps/app/lib/comic_details.dart',
    'typedef ComicDetailsArtworkLoader = Future<EncodedResourceSource> Function({',
    'required String resourceRole,',
    "presentationIdentity: '${comic.sourceId}\\u0000${comic.comicId}'",
    "resourceRole: 'cover',",
)
forbid('apps/app/lib/comic_details.dart', 'ComicDetailsCoverLoader')
require(
    'apps/app/lib/comic_details_extras.dart',
    'final ComicDetailsArtworkLoader loader;',
    'resourceRole: widget.resourceRole,',
    'image: encodedResourceImageProvider(source),',
    'return StableArtworkImage(',
    'The explicit ImageStream listener above is already the decode owner',
)
forbid('apps/app/lib/comic_details_extras.dart', '_ComicDetailsDecodedArtwork(\n            source: source')
require(
    'apps/app/lib/home_shell.dart',
    'required String resourceRole,',
    'resourceRole: resourceRole,',
    "resourceRole: 'cover',",
)
require(
    'docs/SPEC.md',
    'Presentation MUST NOT 自己做定时 retry',
    'MUST NOT 同时构建第二个 `Image`监听同一 provider',
    'Reader route MUST NOT 等待 durable barrier',
)
forbid(
    'docs/SPEC.md',
    'App resume SHOULD 重试仍失败的封面',
    '执行至多一次局部 source revalidation',
)
require('tool/check.sh', 'test_dev158_artwork_loader_compile_blocking_cleanup.py')
print('dev.158 artwork loader / compile / blocking cleanup: OK')
