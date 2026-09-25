#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.310 missing {label}: {token}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
if match is None or int(match.group(1)) < 310:
    raise SystemExit('dev.310 app version missing/regressed')
version = int(match.group(1))
if not re.search(rf'^versionCode={version}$', props, re.M):
    raise SystemExit('dev.310 Android version mismatch')

native = read('packages/reader_runtime/android/src/main/kotlin/dev/zic/readerruntime/ReaderRuntimePlugin.kt')
adapter = read('packages/reader_runtime/lib/src/flutter_reader_platform_frame_cadence.dart')
runtime = read('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
view = read('packages/reader/lib/src/reader_view.dart')
trace = read('packages/telemetry/lib/src/trace.dart')
debug = read('apps/app/lib/debug_trace.dart')
runtime_pubspec = read('packages/reader_runtime/pubspec.yaml')
gradle = read('packages/reader_runtime/android/build.gradle')
manifest = read('packages/reader_runtime/android/src/main/AndroidManifest.xml')
profile = read('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart')
test = read('packages/reader_runtime/test/flutter_reader_platform_frame_cadence_test.dart')

touch_adapter = read('packages/reader_runtime/lib/src/flutter_reader_touch_resampling.dart')
if 'samplingOffset' in touch_adapter:
    raise SystemExit('ADR 0325 must not tune GestureBinding.samplingOffset')
for token in (
    'final class FlutterReaderTouchResamplingLease',
    'binding.resamplingEnabled = true;',
    'GestureBinding.instance.resamplingEnabled = restoreEnabled;',
):
    require(touch_adapter, token, 'ADR 0325 scoped touch resampling')
adr0325 = read('docs/adr/0325-vertical-drag-displacement-resampling.md')
for token in ('20/22', 'ballistic', 'finger-down drag', '0/113', '0.0171%'):
    require(adr0325, token, 'dev.310 ballistic result preserved while drag boundary reopens')

for token in (
    'import android.view.Choreographer',
    'FlutterPlugin,',
    'MethodChannel.MethodCallHandler,',
    'Choreographer.FrameCallback',
    'postFrameCallback(frameCallback)',
    'FRAME_GAP_OUTLIER_MICROS = 20_000L',
    'CALLBACK_LAG_OUTLIER_MICROS = 8_000L',
    'MAX_SAMPLES = 256',
    'startFrameCadenceProbe',
    'drainFrameCadenceProbe',
    'stopFrameCadenceProbe',
    'frameTimeNanos',
    'callbackGapMicros',
    'callbackLagMicros',
):
    require(native, token, 'bounded Android Choreographer observer')

for token in (
    "const Duration(seconds: 2)",
    "kind: TraceEventKind.platformFrameCadenceOutlier",
    "'systemFrameGapMicros': frameGapMicros",
    "'callbackGapMicros': callbackGapMicros",
    "'callbackLagMicros': callbackLagMicros",
    "'callbackOffsetMicros':",
    "(frameTimeNanos - nativeAnchor) ~/ 1000",
    'Future<void> drain()',
    "!kIsWeb && defaultTargetPlatform == TargetPlatform.android",
):
    require(adapter, token, 'low-frequency mapped Dart adapter')
for forbidden in ('SchedulerBinding', 'scheduleFrame(', 'AnimationController(', 'Ticker(', 'ScrollPhysics('):
    if forbidden in adapter:
        raise SystemExit(f'dev.310 cadence adapter changes Flutter scheduling/scroll behavior: {forbidden}')

for token in (
    'FlutterReaderPlatformFrameCadenceProbe? _platformFrameCadenceProbe;',
    'void _syncPlatformFrameCadenceProbe()',
    'reader?.direction == ReadingDirection.vertical',
    '_platformFrameCadenceProbe = probe;',
    'unawaited(probe.start());',
    'unawaited(probe.stop());',
    '_reader = created;\n    _syncTouchResampling();\n    _syncPlatformFrameCadenceProbe();',
    'if (adaptsDirection) {\n      _reader?.setDirection(candidate.direction);\n      _syncExternalPresentationFit();\n      _syncTouchResampling();\n      _syncPlatformFrameCadenceProbe();',
    '_reader?.setDirection(_resolveInitialDirection(_matchingInitialProgress()));\n    _syncExternalPresentationFit();\n    _syncTouchResampling();\n    _syncPlatformFrameCadenceProbe();',
):
    require(runtime, token, 'vertical Reader probe lifecycle')

for token in (
    'final dragDriven = notification.dragDetails != null;',
    "'dragDriven': dragDriven,",
):
    require(view, token, 'retained ballistic attribution')

require(trace, 'platformFrameCadenceOutlier,', 'Trace event kind')
require(debug, 'event.kind != TraceEventKind.platformFrameCadenceOutlier', 'no self-scheduled debug frame')

for token in (
    'pluginClass: ReaderRuntimePlugin',
    'package: dev.zic.readerruntime',
):
    require(runtime_pubspec, token, 'Flutter plugin registration')
for token in ('namespace = "dev.zic.readerruntime"', 'compileSdk = 37', 'minSdk = 21'):
    require(gradle, token, 'reader_runtime Android library')
require(manifest, '<manifest', 'reader_runtime Android manifest')

for token in (
    'native frame cadence outlier maps onto shared Reader trace clock',
    'startFrameCadenceProbe', 'drainFrameCadenceProbe', 'stopFrameCadenceProbe',
    'platformFrameCadenceOutlier', '2000020',
):
    require(test, token, 'cadence adapter regression')

for token in (
    'forwardEncodedPages: 7', 'backwardEncodedPages: 3',
    'forwardDecodePages: 2', 'backwardDecodePages: 1',
):
    require(profile, token, 'frozen resource window')

for tree in ('packages/pipeline', 'packages/pipeline_runtime', 'packages/reader'):
    product = ''.join(path.read_text(encoding='utf-8') for path in (ROOT / tree).rglob('*.dart'))
    if 'platformFrameCadenceOutlier' in product:
        raise SystemExit(f'dev.310 platform cadence diagnostic leaked into behavior owner: {tree}')

all_docs = ''.join(read(path) for path in (
    'CHANGELOG.md', 'docs/ARCHITECTURE.md', 'docs/SPEC.md',
    'docs/IMPLEMENTATION_PLAN.md', 'docs/IMPLEMENTATION_STATUS.md',
    'docs/NEXT_CHAT_HANDOFF.md',
    'docs/adr/0288-vertical-reader-touch-resampling-boundary.md',
    'docs/adr/0289-ballistic-platform-frame-cadence-boundary.md',
    'docs/audits/dev310-ballistic-platform-frame-cadence-audit.md',
))
for token in (
    '20/22', '28.2005ms', '42.888ms', 'ballistic',
    'platformFrameCadenceOutlier', 'Choreographer', '256', '2s',
    '## Status\n\nSuperseded',
):
    require(all_docs, token, 'governed ballistic/platform cadence boundary')

for path, limit in (
    ('docs/IMPLEMENTATION_PLAN.md', 180),
    ('docs/IMPLEMENTATION_STATUS.md', 220), ('docs/NEXT_CHAT_HANDOFF.md', 80),
):
    count = len(read(path).splitlines())
    if count > limit:
        raise SystemExit(f'dev.310 documentation budget exceeded: {path} {count}>{limit}')

print('dev.310 ballistic/platform frame-cadence boundary: OK')
