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
maintenance = read('packages/resource_cache/lib/src/resource_cache_maintenance.dart')
storage = read('packages/storage/lib/src/file_resource_cache_byte_store.dart')
catalog = read('packages/catalog/lib/src/cached_comic_source.dart')
home = read('apps/app/lib/home_shell.dart')
details = read('apps/app/lib/comic_details.dart')

# dev.165 accidentally deleted maintenance contracts together with the file
# borrowing API. Restore only pure usage/trim contracts, never the path facade.
for token in (
    'final class ResourceCacheByteStoreUsage',
    'final class ResourceCacheByteStoreTrimReport',
    'abstract interface class ResourceCacheByteStoreMaintenance',
    'Future<ResourceCacheByteStoreUsage?> inspectPersistentBytes()',
    'Future<ResourceCacheByteStoreTrimReport?> trimPersistentBytesTo',
):
    require(cache, token, 'durable maintenance contract')
for stale in (
    'PersistedResourceFile',
    'ResourceCacheByteStoreFileAccess',
    'ResourceCacheFileByteStore',
    'Future<PersistedResourceFile?> locate(',
):
    forbid(cache + storage, stale, 'borrowed cache-file facade')

# Persistence lifetime is separate from cache identity and memory TTL. Retained
# cover bytes must not share transient LRU/TTL capacity pressure.
for token in (
    'enum ResourceCacheRetention',
    'transient,',
    'retained,',
    'final Map<ResourceCacheKey, Object> _retainedPersistence',
    'Future<bool> retain(ResourceCacheKey key);',
    'expiresAt: retention == ResourceCacheRetention.retained',
):
    require(cache, token, 'retention ownership')
for token in (
    'this.transientMaxEntries = 96',
    'this.transientMaxBytes = 32 * 1024 * 1024',
    'candidate.record.retention == ResourceCacheRetention.transient',
    'candidate.record.retention == ResourceCacheRetention.retained',
    'clearExpiresAt: true',
    "'retention': retention.name",
):
    require(storage, token, 'transient/retained durable store split')
require(
    maintenance,
    'transientPersistentResponseTargetWeight',
    'transient-only persistent maintenance target',
)
forbid(
    maintenance,
    'persistentResponseTargetWeight',
    'ambiguous persistent maintenance target',
)

# Source browse stays transient by default. Library/history/details cover is
# promoted on the same canonical key; preview/avatar remain transient.
require(
    home,
    "resourceRole == 'cover'\n            ? ResourceCacheRetention.retained\n            : ResourceCacheRetention.transient",
    'semantic artwork retention selection',
)
require(
    catalog,
    'ResourceCacheRetention retention = ResourceCacheRetention.transient',
    'catalog cache retention passthrough',
)

# A details/chapter refresh must not erase artwork merely because all responses
# once shared the same comic namespace. Full resource deletion remains explicit.
for token in (
    'void invalidateComicMetadata(String comicId)',
    'key.kind != ResourceCacheKind.imageBytes',
    'void invalidateAllComicResources(',
    'void invalidateCachedComicMetadata(',
):
    require(catalog, token, 'metadata/artwork invalidation split')
require(details, 'invalidateCachedComicMetadata(source, comicId)', 'details metadata refresh')
require(home, 'invalidateAllComicResources(', 'explicit comic resource deletion')
for stale in (
    'void invalidateComic(String comicId)',
    'void invalidateCachedComic(',
    'void invalidateComicResourceCache(',
):
    forbid(catalog, stale, 'broad comic invalidation API')

# Compile regression guard for the user-reported dev.165 failure.
for token in (
    'implements ResourceCacheByteStore,\n    ResourceCacheByteStoreMaintenance',
    'Future<ResourceCacheByteStoreUsage> inspect() async',
    'Future<ResourceCacheByteStoreTrimReport> trimTo',
):
    require(storage, token, 'storage maintenance implementation')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 166:
    raise SystemExit('App build must be at least 166')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.166 retained artwork cache ownership: OK')
