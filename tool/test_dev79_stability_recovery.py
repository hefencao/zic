#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def text(path: str) -> str:
    return (ROOT / path).read_text()

adapter = text('packages/plugin_host/lib/src/runtime_source_adapter.dart')
assert 'plugin.format == ExternalComicPluginFormat.veneraJavaScript' in adapter
assert '? 1\n                  : limits.maxConcurrentInvocations' in adapter
assert 'if (_active >= maxConcurrentInvocations)' in adapter

venera = text('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt')
assert '__zicInstallComicInfoCache' not in venera
assert 'async function __zicInvoke' in venera

home = text('apps/app/lib/home_shell.dart')
# dev.156 supersedes the old scheme-specific migration fallback: every
# non-local artwork URI, including mihon:resource, uses the source gateway.
assert home.count("if (sourceId != 'local-folder' && uri != null)") >= 2
assert "if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https'))" not in home
migration = home[home.index('Future<Uint8List> _loadMigrationCoverBytes'):home.index('Future<EncodedResourceSource> _loadCoverSource')]
assert '_sourceResources.loadArtworkBytes(' in migration
assert 'cacheComicId: _canonicalComicId(sourceId, comicId)' in migration

cache = text('packages/resource_cache/lib/src/resource_cache.dart')
# dev.165 supersedes the old file-source-specific image join: generic byte
# in-flight ownership now returns a presentation-owned memory source.
assert 'Future<EncodedResourceSource> getOrLoadEncodedImage' in cache
assert 'return MemoryEncodedResourceSource(bytes);' in cache
assert '_encodedImageInFlight' not in cache
assert 'Future<EncodedResourceSource> _resolveEncodedImage' not in cache

download = text('packages/sessions/lib/src/download_session.dart')
ingress_projection = text(
    'packages/sessions/lib/src/download_ingress_projection.dart'
)
assert '(current.sourceReady || current.failure != null)' in ingress_projection
assert 'before.length != after.length' in ingress_projection
assert 'before.sourceReady != after.sourceReady' in ingress_projection
assert 'before.failure != after.failure' in ingress_projection
assert 'bool fireImmediately = true' in ingress_projection
assert (
    '_traceIngressProjection(projection.scopeId, before, projection.snapshot);'
    in download
)

decode = text('packages/sessions/lib/src/decode_session.dart')
assert "message: 'frame decode failed'" in decode
assert '_setFailure(failure);' in decode
assert 'final ingressFailure = ingressSnapshot.failure;' in decode
assert '_setFailure(ingressFailure);' in decode

upload = text('packages/sessions/lib/src/upload_session.dart')
assert 'decodeSnapshot.state == DecodeState.failed' in upload
assert "message: 'pipeline page decode failed'" in upload

coordinator = text('packages/sessions/lib/src/live_coordinator.dart')
assert "'decode'," in coordinator
assert "'laneQueueMicros': decodeLaneQueueMicros" in coordinator
assert "'taskElapsedMicros':" in coordinator
assert "_wakeUpload(sessionId, id);" in coordinator
assert '_sourceRevisions[id] = snapshot.revision;' in coordinator
assert '_wakeDecodesForSource(sessionId, id);' in coordinator

reader = text('packages/reader/lib/src/reader_view.dart')
geometry = text('packages/reader/lib/src/vertical_reader_geometry.dart')
assert 'currentIndex' not in geometry
assert 'if (!hasMeasuredRatio)' in geometry
assert 'anchorForTop(' in reader
assert 'restoreTop(' in reader
assert 'anchor.offset.clamp' in geometry

settings = text('packages/reader_runtime/lib/src/reader_session_settings.dart')
runtime = text('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
assert 'final class AdaptiveReaderClassifier' in settings
assert 'observeAnimated(PageAsset page)' in settings
assert "_classifyAnimated('decoded-animation')" in settings
assert '_adaptiveClassifier.observeAnimated(asset)' in runtime
assert 'runtimeAnimatedReaderProfile' not in settings

assert (ROOT / 'docs/audits/dev79-stability-recovery-audit.md').exists()
print('dev.79 stability recovery ownership: OK')
