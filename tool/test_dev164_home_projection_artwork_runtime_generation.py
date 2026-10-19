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
gateway = read('apps/app/lib/source_resource_gateway.dart')
home = read('apps/app/lib/home_shell.dart')
reader_route = read('apps/app/lib/home_shell_reader_route.dart')
session = read('apps/app/lib/home_library_session.dart')
source_compat = read('apps/app/lib/home_shell_source_compat.dart')
source_migration = read('apps/app/lib/home_shell_source_migration.dart')
catalog_identity = read('apps/app/lib/home_shell_catalog_identity.dart')

require(cache, "const comicArtworkCacheSchemaRevision = 'artwork-v2';", 'single artwork schema revision')
for token in (
    "String contentRevision = ''",
    'final cacheRevision = _artworkRevision(contentRevision);',
    '? comicArtworkCacheSchemaRevision',
    "'$comicArtworkCacheSchemaRevision:$contentRevision'",
):
    require(gateway, token, 'gateway-owned artwork revision')
for stale in (
    'comicArtworkCacheRevision',
    "const _artworkCacheSchemaRevision = 'artwork-v2'",
):
    forbid(gateway + home, stale, 'caller-owned artwork schema revision')
# External Home/details/history calls must use the gateway default schema. Local
# artwork still passes the shared schema directly to ResourceCacheManager.
forbid(home, 'contentRevision:', 'Home external artwork cache schema override')
require(home, 'revision: comicArtworkCacheSchemaRevision', 'local artwork shared schema revision')

for token in (
    'Future<ImportedLibraryEntry> upsertChapter(',
    'Future<void> upsertSavedComic(',
    'Future<void> removeChapter(',
    'Future<void> removeSavedComic(',
    'Future<void> persistProgress(',
    'final identity = chapterLibraryIdentity(',
    'int _libraryProjectionRevision = 0;',
    'final projectionRevisionAtStart = _libraryProjectionRevision;',
    '_libraryProjectionRevision == projectionRevisionAtStart',
):
    require(session, token, 'Home library write-through projection')
for text, label in (
    (home, 'home'),
    (source_compat, 'source compatibility'),
    (source_migration, 'source migration'),
    (catalog_identity, 'catalog identity'),
):
    for stale in (
        '_library.upsertChapter(',
        '_library.upsertSavedComic(',
        '_library.removeChapter(',
        '_library.removeSavedComic(',
    ):
        forbid(text, stale, f'{label} direct durable projection mutation')

for token in (
    'ReadingProgress? latestProgress;',
    'latestProgress = progress;',
    'return _enqueueReaderProgress(progress);',
    '_librarySession.replaceProgress(progress);',
    'onProgressChanged: onProgressChanged',
):
    require(home + reader_route, token, 'route-local Reader progress handoff')
for stale in ('_latestReaderProgress', '_publishReaderProgressAfterRoute', '_saveReaderProgress'):
    forbid(home + reader_route, stale, 'global Reader progress handoff')

runtime = read('packages/plugin_host_bridge/lib/src/method_channel_runtime_backends.dart')
client = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/PluginRuntimeServiceClient.kt')
policy = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/RuntimeServiceRequestLifecyclePolicy.kt')
for stale in ('_recoverableActivationRuntimeCodes', 'Replay activation once at this infrastructure boundary'):
    forbid(runtime, stale, 'Dart plugin-level activation retry')
for token in (
    'replayInitialActivationsAfterServiceLoss',
    'call.serviceGenerationReplays += 1',
    'retained += OutgoingRequest(call.requestId, call.payload)',
    'failures.forEach { call -> call.result.error(code, message, null) }',
):
    require(client, token, 'Binder generation continuity owner')
for token in (
    'method in activationMethods',
    'code in replaceableServiceLossCodes',
    'completedReplays == 0',
):
    require(policy, token, 'bounded activation transport continuity')

version = re.search(r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 164:
    raise SystemExit('App build must be at least 164')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.164 Home projection + artwork revision + runtime generation ownership: OK')
