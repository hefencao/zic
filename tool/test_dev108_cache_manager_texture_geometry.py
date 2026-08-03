#!/usr/bin/env python3
"""Guard dev.108 page-artifact routing and Android surface configuration."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def read(path): return (ROOT/path).read_text(encoding='utf-8')
def require(text, token, owner):
    if token not in text: raise SystemExit(f'{owner} is missing dev.108 contract: {token}')
store=read('packages/downloads/lib/src/artifact_cache_store.dart')
manager=read('packages/downloads/lib/src/artifact_cache_manager.dart')
transport=read('packages/downloads/lib/src/artifact_cache_transport.dart')
handoff=read('packages/downloads/lib/src/promoted_artifact_cache_handoff.dart')
pipeline=read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
app=read('apps/app/lib/demo_home.dart')+read('apps/app/lib/demo_home_reader_route.dart')
kotlin=read('packages/texture_bridge/android/src/main/kotlin/dev/zic/texture/TextureBridgePlugin.kt')
rust=read('native/media_core/src/android_texture.rs')
lane=read('packages/sessions/lib/src/net_lane.dart')
coordinator=read('packages/sessions/lib/src/live_coordinator.dart')
chapter=read('packages/downloads/lib/src/chapter_downloads.dart')
for token in ('abstract interface class ArtifactCacheBackend', 'implements ArtifactCacheStore, ArtifactCacheStreamStore'):
    require(store, token, 'artifact backend boundary')
if 'ArtifactCachePresenceStore' in store:
    raise SystemExit('backend-specific presence capability must remain removed')
for token in ('final class ArtifactCacheManager', 'ArtifactCacheTier.memory', 'ArtifactCacheTier.persistent', 'Future<bool> contains(', 'Future<bool> containsBackend(', 'readForegroundLookup(', 'readSessionArtifact('):
    require(manager, token, 'artifact cache manager')
for token in ('required ArtifactCacheManager cache', '_cache.lookup(id)', '_cache.readForegroundLookup(lookup)'):
    require(transport, token, 'artifact transport routing')
require(handoff, 'cache.containsBackend(', 'artifact handoff write-through')
if 'cache.contains(' in handoff:
    raise SystemExit('handoff must not treat memory visibility as durable presence')
if 'PromotedArtifactReadPool' in pipeline or 'artifactByteCache' in pipeline:
    raise SystemExit('pipeline must not own a second artifact tier/router')
for token in ('ArtifactCacheManager? artifactCacheManager', 'withArtifactCacheManager(', 'cache?.lookupMemory(id)', 'cache.readSessionArtifact('):
    require(pipeline, token, 'pipeline cache composition')
for token in ('late final ArtifactCacheManager? _readerArtifactCache', 'ArtifactCacheManager(', 'withArtifactCacheManager('):
    require(app, token, 'app cache composition')
for token in ('external fun configure(', 'needsConfiguration = true', 'NativeBlitter.configure(', 'status == BLIT_LOCK_FAILED', 'blitRetryCount'):
    require(kotlin, token, 'Android texture surface configuration')
for token in ('ANativeWindow_setBuffersGeometry', 'Java_dev_zic_texture_NativeBlitter_configure', 'WINDOW_FORMAT_RGBA_8888', 'BLIT_CONFIG_FAILED'):
    require(rust, token, 'native Android surface configuration')

for token in ('_indexedPromotedArtifact(', 'final record = await _index.get(id.key);', 'record.state != CacheState.ready', 'readAll: () => _readIndexedBytes('):
    require(chapter, token, 'persistent artifact indexed backend')
read_artifact_block = chapter[chapter.index('Future<Uint8List?> readArtifact(DownloadId id)', chapter.index('final class PersistentChapterDownloadService')):chapter.index('Future<Artifact?> _promotedArtifactForRead') ]
if '_registry.get(id)' in read_artifact_block:
    raise SystemExit('persistent cache reads must not materialize DownloadSession')

for token in ('void cancelAll();', 'void cancelAll() {'):
    require(lane, token, 'task lane cancellation')
for token in ('net.cancelAll();', 'decode.cancelAll();', 'upload.cancelAll();'):
    require(coordinator, token, 'coordinator shutdown')
if (ROOT/'packages/downloads/lib/src/promoted_artifact_read_pool.dart').exists():
    raise SystemExit('obsolete per-session promoted read pool must stay removed')
print('dev.108 cache manager and texture geometry: OK')
