#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.162 tokens: {missing}')


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} retains superseded boundary tokens: {found}')


require(
    'apps/app/lib/demo_home_source_compat.dart',
    '_sourceResources.loadPageBytes(sourceId, uri)',
)
forbid(
    'apps/app/lib/demo_home_source_compat.dart',
    '_sourceResources.loadBytes(',
)
require(
    'apps/app/lib/source_resource_gateway.dart',
    'HashSet<ConfigurableChapterResourceAccess>.identity()',
    'return _collectResponse(pageResponseLoaderFor(sourceId, uri));',
    'configurable.setChapterResourceAccess(chapterResourceAccess)',
    'configurable.setChapterResourceAccess(null)',
)
forbid(
    'apps/app/lib/source_resource_gateway.dart',
    '_requireSource(sourceId, uri).loadResource(uri)',
    'ConfigurableChapterResourceLoader',
    'ConfigurableChapterResourceTransport',
    'setChapterResourceLoader(',
    'setChapterResourceTransport(',
)
require(
    'packages/downloads/lib/src/chapter_downloads.dart',
    'final class ChapterResourceAccess',
    'abstract interface class ConfigurableChapterResourceAccess',
    'void setChapterResourceAccess(ChapterResourceAccess? access)',
)
forbid(
    'packages/downloads/lib/src/chapter_downloads.dart',
    'abstract interface class ConfigurableChapterResourceLoader',
    'abstract interface class ConfigurableChapterResourceTransport',
    'void setChapterResourceLoader(',
    'void setChapterResourceTransport(',
)
require(
    'packages/catalog/lib/src/cached_comic_source.dart',
    'Artwork is deliberately not loaded here',
    'Future<Uint8List> loadResource(Uri uri) => source.loadResource(uri)',
    'loadCachedComicImage(',
    'loadCachedComicImageSource(',
)
forbid(
    'packages/catalog/lib/src/cached_comic_source.dart',
    'Future<Uint8List> loadImage(',
    'Future<EncodedResourceSource> loadImageSource(',
    'loadCachedSourceImage(',
    'loadCachedSourceImageSource(',
)
check = read('tool/check.sh')
if 'test_dev162_source_resource_atomic_catalog_boundary.py' not in check:
    raise SystemExit('FAIL: dev.162 gate is not integrated into tool/check.sh')
print('dev.162 source-resource atomic/catalog ownership boundary: OK')
