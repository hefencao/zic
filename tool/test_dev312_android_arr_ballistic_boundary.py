#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.312 missing {label}: {token}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
if match is None or int(match.group(1)) < 312:
    raise SystemExit('dev.312 app version missing/regressed')
version = int(match.group(1))
if not re.search(rf'^versionCode={version}$', props, re.M):
    raise SystemExit('dev.312 Android version mismatch')

native = read('packages/reader_runtime/android/src/main/kotlin/dev/zic/readerruntime/ReaderRuntimePlugin.kt')
cadence = read('packages/reader_runtime/lib/src/flutter_reader_platform_frame_cadence.dart')
policy = read('packages/reader_runtime/lib/src/flutter_reader_platform_frame_rate_policy.dart')
runtime = read('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
trace = read('packages/telemetry/lib/src/trace.dart')
debug = read('apps/app/lib/debug_trace.dart')
media = read('packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart')
profile = read('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart')

require(native, 'import android.view.Choreographer', 'correct Choreographer package')
if 'android.os.Choreographer' in native:
    raise SystemExit('dev.312 retained invalid android.os.Choreographer import')
for token in (
    'ActivityAware',
    'Debug.threadCpuTimeNanos()',
    'threadCpuGapMicros',
    'displayRefreshRateMilliHz',
    'displayHasArrSupport',
    'Build.VERSION_CODES.BAKLAVA',
    'hasArrSupport()',
    'setVerticalReaderFrameRatePolicy',
    'Build.VERSION_CODES.VANILLA_ICE_CREAM',
    'isFrameRatePowerSavingsBalanced',
    'previousFrameRatePowerSavingsBalanced',
    'restoreFrameRatePolicy',
    'onDetachedFromActivityForConfigChanges',
    'onReattachedToActivityForConfigChanges',
):
    require(native, token, 'Android ARR/cadence boundary')

for token in (
    "'threadCpuGapMicros': threadCpuGapMicros",
    "'displayRefreshRateMilliHz': displayRefreshRateMilliHz",
    "'frameRatePolicyRequested':",
    'frameRatePolicyRequested != 0',
    "'displayHasArrSupport': displayHasArrSupport != 0",
):
    require(cadence, token, 'cadence attribution extension')

for token in (
    "'dev.zic/reader_runtime_frame_rate_policy'",
    'setVerticalReaderFrameRatePolicy',
    "'active': true",
    "'active': active",
    'TraceEventKind.platformFrameRatePolicy',
):
    require(policy, token, 'separate Reader frame-rate policy adapter')
for forbidden in ('jumpTo(', 'animateTo(', 'scheduleFrame(', 'Ticker(', 'AnimationController('):
    if forbidden in policy:
        raise SystemExit(f'dev.312 ARR policy leaked into Reader scheduling: {forbidden}')

if version == 312:
    for token in (
        'FlutterReaderPlatformFrameRatePolicy? _platformFrameRatePolicy;',
        '_platformFrameRatePolicy = policy;',
        'unawaited(policy.start());',
        'unawaited(policy.stop());',
    ):
        require(runtime, token, 'vertical Reader policy lifecycle')
else:
    # dev.313 device evidence rejects ARR as the shared root. The adapter and
    # dev.312 evidence remain, but later production Readers must not keep the
    # behavior intervention active while measuring platform cadence.
    if 'FlutterReaderPlatformFrameRatePolicy' in runtime:
        raise SystemExit('post-dev.312 Reader still activates rejected ARR policy')
require(trace, 'platformFrameRatePolicy,', 'policy trace kind')
require(debug, 'event.kind != TraceEventKind.platformFrameRatePolicy', 'no trace-viewer feedback frame')

# The falsified dev.311 renderer switch is rolled back to the already-known
# dev.310 production texture path; this cannot be mistaken for the new fix.
default_start = media.index('NativePipelineMediaRuntimeFactory() {')
default_end = media.index('\n  }', default_start) + 4
default_ctor = media[default_start:default_end]
require(default_ctor, 'AndroidTexturePresenter.isSupported', 'rolled-back production texture default')
if 'NativePipelineMediaRuntimeFactory.platformTexture()' in media:
    raise SystemExit('dev.312 still uses dev.311 explicit-only texture experiment')

for token in (
    'forwardEncodedPages: 7', 'backwardEncodedPages: 3',
    'forwardDecodePages: 2', 'backwardDecodePages: 1',
):
    require(profile, token, 'frozen resource window')

runtime_product = ''.join(
    path.read_text(encoding='utf-8')
    for path in (ROOT / 'packages/reader_runtime/lib').rglob('*.dart')
)
touch_adapter = read('packages/reader_runtime/lib/src/flutter_reader_touch_resampling.dart')
if 'samplingOffset' in touch_adapter:
    raise SystemExit('ADR 0325 touch resampling must retain Flutter default samplingOffset')
if 'GestureBinding' in read('packages/reader/lib/src/reader_view.dart'):
    raise SystemExit('ADR 0325 leaked framework input ownership into reader')

for path in (
    'packages/reader_runtime/test/flutter_reader_platform_frame_rate_policy_test.dart',
    'docs/archive/adr/0291-vertical-reader-android-arr-boundary.md',
    'docs/archive/audits/dev312-android-arr-ballistic-audit.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'dev.312 artifact missing: {path}')

docs = ''.join(read(path) for path in (
    'CHANGELOG.md', 'docs/ARCHITECTURE.md', 'docs/SPEC.md',
    'docs/IMPLEMENTATION_PLAN.md', 'docs/IMPLEMENTATION_STATUS.md',
    'docs/NEXT_CHAT_HANDOFF.md',
    'docs/archive/adr/0291-vertical-reader-android-arr-boundary.md',
    'docs/archive/audits/dev312-android-arr-ballistic-audit.md',
))
for token in (
    '57', '28.194ms', '70', 'FALSIFIED', 'android.view.Choreographer',
    'isFrameRatePowerSavingsBalanced', 'platformFrameRatePolicy',
    'System Trace', 'Perfetto',
):
    require(docs, token, 'governed ARR falsification boundary')

if version > 312 and '- P0（dev.312）：' in read('docs/IMPLEMENTATION_PLAN.md'):
    raise SystemExit('active Plan still requests the superseded ARR experiment')

print('dev.312 Android ARR ballistic boundary: OK')
