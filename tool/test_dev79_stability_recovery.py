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

home = text('apps/app/lib/demo_home.dart')
assert home.count('if (source != null && uri != null && uri.hasScheme)') >= 2
assert "(uri.scheme == 'http' || uri.scheme == 'https')" not in home[home.index('Future<Uint8List> _loadMigrationCoverBytes'):home.index('Future<ChapterDetailsSnapshot>') if 'Future<ChapterDetailsSnapshot>' in home else len(home)]

cache = text('packages/resource_cache/lib/src/resource_cache.dart')
assert '_encodedImageInFlight' in cache
assert 'Future<EncodedResourceSource> _resolveEncodedImage' in cache
assert '..._encodedImageInFlight.keys' in cache

download = text('packages/sessions/lib/src/download_session.dart')
assert '(after.sourceReady || after.failure != null)' in download
assert 'before.length != after.length' in download
assert 'bool fireImmediately = true' in download
assert '_traceIngress(before, targetIngress.snapshot);' in download

decode = text('packages/sessions/lib/src/decode_session.dart')
assert "message: 'frame decode failed'" in decode
assert '_setFailure(failure);' in decode
assert 'final ingressFailure = ingressSnapshot?.failure;' in decode
assert '_setFailure(ingressFailure);' in decode

upload = text('packages/sessions/lib/src/upload_session.dart')
assert 'decodeSnapshot.state == DecodeState.failed' in upload
assert "message: 'pipeline page decode failed'" in upload

coordinator = text('packages/sessions/lib/src/live_coordinator.dart')
assert "_error(sessionId, entry.key.key, 'decode', error);\n              _wakeUpload(sessionId, entry.key);" in coordinator
assert "_error(sessionId, id.key, 'decode', error);" in coordinator
assert "_wakeUpload(sessionId, id);" in coordinator
assert '_sourceRevisions[id] = snapshot.revision;' in coordinator
assert 'Every emitted ingress lifecycle change can unblock or terminate decode' in coordinator

reader = text('packages/reader/lib/src/reader_view.dart')
geometry = text('packages/reader/lib/src/vertical_reader_geometry.dart')
assert 'currentIndex' not in geometry
assert 'if (!hasMeasuredRatio)' in geometry
assert 'anchorForTop(' in reader
assert 'restoreTop(' in reader
assert 'anchor.offset.clamp' in geometry

settings = text('packages/reader_runtime/lib/src/reader_session_settings.dart')
runtime = text('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
assert 'runtimeAnimatedReaderProfile' in settings
assert "basis: 'runtime-animation'" in settings
assert 'runtimeAnimatedReaderProfile(widget.chapter)' in runtime

assert (ROOT / 'docs/audits/dev79-stability-recovery-audit.md').exists()
print('dev.79 stability recovery ownership: OK')
