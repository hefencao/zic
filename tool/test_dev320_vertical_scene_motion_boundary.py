#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.320 missing {label}: {token}')


def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.320 forbidden {label}: {token}')


pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
if match is None or int(match.group(1)) < 320:
    raise SystemExit('dev.320+ version mismatch')
version = int(match.group(1))
if not re.search(rf'^versionCode={version}$', props, re.M):
    raise SystemExit('dev.320 Android version mismatch')

reader = read('packages/reader/lib/src/reader_view.dart')
trace = read('packages/telemetry/lib/src/trace.dart')
debug = read('apps/app/lib/debug_trace.dart')
native = read('packages/reader_runtime/android/src/main/kotlin/dev/zic/readerruntime/ReaderRuntimePlugin.kt')
adapter = read('packages/reader_runtime/lib/src/flutter_reader_platform_frame_cadence.dart')
session = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
player = read('packages/local_media_ui/lib/src/local_image_player.dart')

# Keep the only device-supported behavior change from dev.317.
require(session, 'Timer.run(() => _drainObservation(generation));', 'dev.317 event-turn seam')
if re.search(r'final provider\s*=\s*detected\.isWebp\s*\?\s*null\s*:\s*encodedResourceImageProvider\(\s*MemoryEncodedResourceSource\(', player) is None:
    raise SystemExit('dev.320 missing native WebP presentation through encoded-resource provider')

# The scene probe observes one final post-frame position without requesting frames.
for token in (
    '_startVerticalSceneMotionProbe()',
    '_scheduleVerticalSceneMotionSample()',
    'WidgetsBinding.instance.addPostFrameCallback((frameTimeStamp)',
    'frameTimeStamp.inMicroseconds',
    'renderObject.localToGlobal(Offset.zero).dy',
    'final residual = globalTop + position.pixels - expectedStart;',
    "'layoutResidualDeltaPx'",
    "'stationaryBallisticCount'",
    "'maxAbsLayoutResidualDeltaPx'",
):
    require(reader, token, 'per-frame scene-motion observation')
probe = reader[reader.index('void _startVerticalSceneMotionProbe()'):reader.index('void _resetVerticalScrollCadenceSummary')]
for token in ('scheduleFrame(', 'setState(', '.jumpTo(', '.animateTo('):
    forbid(probe, token, 'probe-driven Reader behavior')

for token in ('verticalSceneMotionOutlier,', 'verticalSceneMotionSummary,'):
    require(trace, token, 'scene trace kind')
for token in (
    'event.kind != TraceEventKind.verticalSceneMotionOutlier',
    'event.kind != TraceEventKind.verticalSceneMotionSummary',
):
    require(debug, token, 'scene trace no-feedback rule')

# dev.319 Window metrics are retained but corrected as sparse diagnostics.
for token in (
    'lastWindowMetricVsyncNanos',
    'vsyncNanos == lastWindowMetricVsyncNanos',
    'windowSummaryFirstVsyncNanos',
    'windowSummaryLastVsyncNanos',
    '"firstVsyncNanos"',
    '"lastVsyncNanos"',
):
    require(native, token, 'Window FrameMetrics dedupe/coverage metadata')
for token in ("'firstVsyncNanos'", "'lastVsyncNanos'"):
    require(adapter, token, 'Window coverage projection')

# Do not re-open already falsified motion hacks.
product = reader + session + player
for token in (
    'Duration(milliseconds: 180)',
    'GestureBinding.resamplingEnabled',
    'samplingOffset =',
    'setRequestedFrameRate(',
):
    forbid(product, token, 'superseded behavior experiment')

for rel in (
    'tool/analyze_vertical_scene_motion_jank.py',
    'docs/adr/0299-vertical-scene-motion-frame-boundary.md',
    'docs/audits/dev320-vertical-scene-motion-frame-audit.md',
):
    if not (ROOT / rel).is_file():
        raise SystemExit(f'dev.320 missing artifact: {rel}')

docs = ''.join(read(path) for path in (
    'CHANGELOG.md', 'docs/ARCHITECTURE.md', 'docs/SPEC.md',
    'docs/IMPLEMENTATION_PLAN.md', 'docs/IMPLEMENTATION_STATUS.md',
    'docs/NEXT_CHAT_HANDOFF.md',
    'docs/adr/0298-android-window-frame-metrics-boundary.md',
    'docs/adr/0299-vertical-scene-motion-frame-boundary.md',
    'docs/audits/dev320-vertical-scene-motion-frame-audit.md',
))
for token in (
    '2052', '1989', '8.419ms', 'FrameMetrics', '62',
    'scene', 'SurfaceFlinger', 'dev.317',
):
    require(docs, token, 'high-performance/device-governance evidence')

print('dev.320 vertical scene-motion frame boundary: OK')
