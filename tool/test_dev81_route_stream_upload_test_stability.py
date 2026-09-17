#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


activity = read('apps/app/android/app/src/main/kotlin/dev/zic/zic/MainActivity.kt')
transport = read('packages/downloads/lib/src/source_resource_transport.dart')
transport_test = read('packages/downloads/test/source_resource_transport_test.dart')
download = read('packages/sessions/lib/src/download_session.dart')
download_test = read('packages/sessions/test/download_session_test.dart')
upload = read('packages/sessions/lib/src/upload_session.dart')
upload_test = read('packages/sessions/test/upload_session_test.dart')
progress = read('packages/pipeline_runtime/lib/src/pipeline_transfer_progress.dart')
media = read('packages/local_media_ui/lib/src/local_image_player.dart')
texture = read('packages/texture_bridge/lib/src/native_texture_viewport.dart')
details = read('apps/app/lib/comic_details.dart')
home = read('apps/app/lib/demo_home.dart')
reader_composition = read('apps/app/lib/demo_home_reader_route.dart')
deferred = read('apps/app/lib/deferred_reader_route.dart')
deferred_test = read('apps/app/test/deferred_reader_route_test.dart')
gateway_test = read('apps/app/test/source_resource_gateway_test.dart')
reader_test = read('packages/reader/test/reader_navigation_test.dart')
geometry = read('packages/reader/lib/src/vertical_reader_geometry.dart')
geometry_test = read('packages/reader/test/vertical_reader_geometry_test.dart')
runtime_adapter = read('packages/plugin_host/lib/src/runtime_source_adapter.dart')
mihon_driver = read(
    'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/'
    'MihonRuntimeDriver.kt'
)

for token in (
    'Intent.ACTION_CREATE_DOCUMENT',
    'startActivityForResult(intent, TRACE_EXPORT_REQUEST)',
    'override fun onActivityResult',
):
    assert token in activity
assert 'registerForActivityResult' not in activity

for token in (
    'typedef SourceResourceDirectOpen',
    'normalizeSourceResourceRequest(',
    'ExternalPluginResourceTransportPool({',
    'SourceResourceDirectOpen? directOpen',
    '_openRetryPlan(',
):
    assert token in transport
assert transport_test.count('HttpServer.bind') == 1
assert 'controlled cancellation aborts an already streaming host response' in transport_test
# dev.81 banned a historical 30s fixed wait in this suite. A later transport
# contract intentionally uses a positive 30s *capability value* on
# _BoundedFixtureSource to prove that source-operation and direct-open owners
# jointly form SelfBoundedOpenTransport. Keep the timing-stability rule aimed
# at blocking real waits instead of forbidding that bounded-source fixture.
assert 'Future<void>.delayed(const Duration(seconds: 30))' not in transport_test
assert 'pump(const Duration(seconds: 30))' not in transport_test
assert (
    'Duration get resourceOperationTimeout => const Duration(seconds: 30);'
    in transport_test
)
assert '_ControlledBody' in transport_test
for transport_contract_test in (
    'retry request with explicit transform uses source-owned byte transform',
    'source-client state mismatch still falls back to runtime ownership',
    'retry replacement network failure stays on streaming transport',
):
    assert transport_contract_test in transport_test

for token in (
    'Future<void> _prepareTail = Future<void>.value();',
    'int _pendingPrepares = 0;',
    '_serializePrepare(',
    'bool _releaseUploaderWhenIdle = false;',
    '_requestUploaderRelease()',
    '_flushUploaderRelease()',
):
    assert token in upload
for token in ('_ControlledUploader', '_SequencedControlledUploader', 'Completer<OutputFrame>'):
    assert token in upload_test

for token in (
    'required this.networkStartLength',
    '_networkStartLength = committedLength;',
):
    assert token in download
assert 'snapshot owns the resume baseline' in download_test
assert 'snapshot.networkCursorLength' in progress
assert 'snapshot.networkAttemptSequence' in progress
assert 'snapshot.networkStartLength' not in progress
assert '_lastStates' not in progress
assert '_existingBytes' not in progress

assert 'alignment: mediaAlignmentFor(fit)' in media
assert (
    'fit == BoxFit.fitWidth ? Alignment.topCenter : Alignment.center' in media
)
assert 'alignment: Alignment.center' in texture
assert 'Alignment.topCenter' not in texture

for token in (
    'typedef ComicDetailsChapterLoader',
    'required String title',
    'DeferredReaderRoute<_PreparedImportedChapter>',
    '_readerChapterComposition.prepare(',
):
    assert token in details + home + reader_composition
for token in ('deferredReaderRouteKey', 'deferredReaderLoadingKey', 'widget.load()'):
    assert token in deferred

assert "find.byKey(const ValueKey<String>('reader-vertical-gap:0'))" not in reader_test
assert 'greaterThan(600)' not in reader_test
assert '_pumpUntilCondition' not in reader_test
for fixed_wait in ('Duration(milliseconds: 80)', 'Duration(milliseconds: 50)', 'Duration(milliseconds: 400)'):
    assert fixed_wait not in reader_test
assert 'nowMicros = widget.clock.nowMicros()' in read('packages/reader/lib/src/reader_view.dart')
pubspec = read('apps/app/pubspec.yaml')
version_match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
current_dev = int(version_match.group(1)) if version_match else 0
settled_gesture_count = reader_test.count(
    'await gesture.up();\n      await tester.pumpAndSettle();'
)
if current_dev < 308:
    assert settled_gesture_count == 2
    assert reader_test.count('pumpAndSettle') == 2
else:
    # dev.308 adds a deterministic reverse-prefix geometry regression that
    # settles after gesture end; keep dev.81's ban on fixed waits while no
    # longer treating the historical test count as an ownership contract.
    assert settled_gesture_count >= 2
    assert reader_test.count('pumpAndSettle') >= 2
for token in (
    'final class ReaderVerticalGeometry',
    'ReaderVerticalAnchor anchorForTop',
    'double restoreTop',
):
    assert token in geometry
for token in ('boundsAt(1)', 'anchorForTop(top)', 'restoreTop(anchor)'):
    assert token in geometry_test

assert '_format != ExternalComicPluginFormat.veneraJavaScript' not in runtime_adapter
assert 'ExternalComicPluginFormat.mihonExtension' in runtime_adapter
for token in (
    '"resolveResource" -> resolveResource(',
    'private fun resolveResource(',
    'enforceSourceRequestLimit(sourceId, source)',
    'mihonSourceRequiresRuntimeTransform(source)',
):
    assert token in mihon_driver

for text, label in (
    (upload_test, 'upload session'),
    (deferred_test, 'deferred Reader route'),
    (gateway_test, 'source resource gateway'),
):
    for unstable in (
        'HttpServer.bind',
        'ServerSocket.bind',
        'Future.delayed',
        'pumpAndSettle',
        'Duration(seconds: 30)',
    ):
        assert unstable not in text, f'{label} test retains unstable {unstable}'
for unstable in (
    'ServerSocket.bind',
    'Future.delayed',
    'pumpAndSettle',
):
    assert unstable not in transport_test, (
        f'downloads transport test retains unstable {unstable}'
    )
assert 'package:flutter_test/flutter_test.dart' not in geometry_test
for token in ('_ResolvedSource', 'source.resolveCalls', 'source.loads'):
    assert token in gateway_test

assert (ROOT / 'docs/adr/0065-route-first-reader-and-inflight-upload-lifecycle.md').is_file()
assert (ROOT / 'docs/audits/dev81-reader-route-streaming-and-test-stability-audit.md').is_file()
print('dev.81 route-first Reader, direct streaming and deterministic tests: OK')
