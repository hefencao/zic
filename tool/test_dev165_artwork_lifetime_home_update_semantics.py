#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')


def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'superseded {label}: {token}')


cache = read('packages/resource_cache/lib/src/resource_cache.dart')
storage = read('packages/storage/lib/src/file_resource_cache_byte_store.dart')
home = read('apps/app/lib/home_shell.dart')
views = read('apps/app/lib/home_shell_views.dart')
catalog_identity = read('apps/app/lib/home_shell_catalog_identity.dart')
migration = read('apps/app/lib/home_shell_source_migration.dart')
saved = read('packages/catalog/lib/src/saved_comic.dart')
library_comic = read('packages/catalog/lib/src/library_comic.dart')

# A response-cache file may be trimmed independently of Flutter ImageProvider
# lifetime, so cache-owned files must never cross the response-cache boundary.
for stale in (
    'PersistedResourceFile',
    'ResourceCacheByteStoreFileAccess',
    'ResourceCacheFileByteStore',
    'Future<PersistedResourceFile?> locate(',
    '_fileEntries',
    '_encodedImageInFlight',
):
    forbid(cache + storage, stale, 'borrowed response-cache file lifetime')
for token in (
    'return MemoryEncodedResourceSource(bytes);',
    'origin: EncodedResourceOrigin.durableCacheFile',
    'EncodedResourceOrigin origin = EncodedResourceOrigin.localFile',
    'assert(origin != EncodedResourceOrigin.memory)',
    'super(origin: origin)',
):
    require(cache, token, 'owned encoded artwork source')
forbid(cache, 'EncodedResourceOrigin origin = EncodedResourceOrigin.durableCacheFile',
       'durable FileEncodedResourceSource')

# Update feed is source-confirmed state, not metadata/read recency.
for token in (
    'final DateTime? sourceUpdateAt;',
    "'sourceUpdateAt': sourceUpdateAt!.toIso8601String()",
    'clearSourceUpdateAt',
):
    require(saved, token, 'durable source update signal')
require(library_comic, 'final DateTime? sourceUpdateAt;', 'library update projection')
for token in (
    '_manifestChapterCatalogDiffers',
    '_manifestChapterCatalogChanged',
    'chapterCatalogChanged ? now : existing?.sourceUpdateAt',
):
    require(catalog_identity + home, token, 'chapter-catalog update detection')
forbid(migration, 'Future<void> _reconcileConfirmedSourceUpdateSignal(',
       'superseded version-to-chapter-signal mirroring')
forbid(migration, 'if (!discoveredNewVersion) return;',
       'one-shot version update detection')
if re.search(
    r'_sourceUpdateAtForComic\(comic\)\s*!=\s*null\s*&&\s*'
    r'_preferenceForComic\(comic(?:,\s*aliases:\s*'
    r'identityQuery\.aliasesFor\(comic\.sourceId,\s*comic\.comicId\),\s*)?\)\.inShelf',
    views,
) is None:
    raise SystemExit('missing Home source-update then shelf-preference filter')
for token in (
    '_sourceUpdateAtForComic(right)!',
    '加入书架的漫画有新章节或新版本时显示',
):
    require(views, token, 'Home update feed semantics')
for stale in (
    'right.metadataUpdatedAt.compareTo(left.metadataUpdatedAt)',
    "subtitle: updates.isEmpty ? '导入漫画后会显示最近更新' : null",
):
    forbid(views, stale, 'metadata-recency update feed')
require(home, "fallbackInShelf: comic.sourceId == 'local-folder'", 'remote unknown shelf fallback')
require(home, 'bool fallbackInShelf = false,', 'neutral preference fallback')
require(home, 'if (!previous.inShelf && updated.inShelf)', 'shelf transition update reset')
require(home, 'saved.copyWith(', 'stale pre-shelf update owner')
require(home, 'clearSourceUpdateAt: true', 'stale pre-shelf update reset')

version = re.search(r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 165:
    raise SystemExit('App build must be at least 165')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.165 artwork lifetime + Home update semantics: OK')
