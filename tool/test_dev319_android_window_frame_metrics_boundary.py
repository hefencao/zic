#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path):
    return (ROOT / path).read_text(encoding='utf-8')

def require(text, token, label):
    if token not in text:
        raise SystemExit(f'dev.319 missing {label}: {token}')

def forbid(text, token, label):
    if token in text:
        raise SystemExit(f'dev.319 forbidden {label}: {token}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
m = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
if m is None or int(m.group(1)) < 319:
    raise SystemExit('dev.319+ version mismatch')
version = int(m.group(1))
if not re.search(rf'^versionCode={version}$', props, re.M):
    raise SystemExit('dev.319 Android version mismatch')

native = read('packages/reader_runtime/android/src/main/kotlin/dev/zic/readerruntime/ReaderRuntimePlugin.kt')
adapter = read('packages/reader_runtime/lib/src/flutter_reader_platform_frame_cadence.dart')
trace = read('packages/telemetry/lib/src/trace.dart')
debug = read('apps/app/lib/debug_trace.dart')
player = read('packages/local_media_ui/lib/src/local_image_player.dart')
session = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
reader = read('packages/reader/lib/src/reader_view.dart')

# dev.317's observed low-device benefit remains the only behavior change.
require(session, 'Timer.run(() => _drainObservation(generation));', 'dev.317 event-turn retention')
for token in ('Duration(milliseconds: 180)', 'GestureBinding.resamplingEnabled', 'setRequestedFrameRate(', 'preferredRefreshRate ='):
    forbid(session + reader + player, token, 'unrelated behavior experiment')

# dev.318 valid projection is now device-falsified and production presentation is restored.
for token in ('_isAuthoritativeStaticWebpOutput', '_buildStaticWebpProjection(', 'pipeline-texture-fallback-to-compressed-flutter-image'):
    forbid(player, token, 'dev.318 static projection')
require(player, 'detected.isWebp ? null : MemoryImage(bytes)', 'native WebP presentation restoration')
require(reader, '_recordVerticalScrollCadenceSummary', 'retained motion cadence observation')

# FrameMetrics is Window-owned observation, isolated from Android main callback execution.
for token in (
    'import android.view.FrameMetrics',
    'Window.OnFrameMetricsAvailableListener',
    'HandlerThread("zic-reader-window-metrics")',
    'addOnFrameMetricsAvailableListener(listener, handler)',
    'removeOnFrameMetricsAvailableListener(listener)',
    'FrameMetrics.UNKNOWN_DELAY_DURATION',
    'FrameMetrics.SYNC_DURATION',
    'FrameMetrics.COMMAND_ISSUE_DURATION',
    'FrameMetrics.SWAP_BUFFERS_DURATION',
    'Build.VERSION.SDK_INT >= Build.VERSION_CODES.O',
    'drainWindowFrameMetricsProbe',
    'drainWindowFrameMetricsSummary',
    'droppedReports',
):
    require(native, token, 'Android Window FrameMetrics probe')
for token in ('droppedFrames"', 'windowSummaryDroppedFrames'):
    forbid(native, token, 'mislabelled FrameMetrics report loss')

for token in (
    "'drainWindowFrameMetricsProbe'",
    "'drainWindowFrameMetricsSummary'",
    'TraceEventKind.platformWindowFrameMetricsOutlier',
    'TraceEventKind.platformWindowFrameMetricsSummary',
    "'unknownDelayMicros'",
    "'swapBuffersMicros'",
    "'droppedReports'",
):
    require(adapter, token, 'Dart Window metrics projection')
for token in ('platformWindowFrameMetricsOutlier,', 'platformWindowFrameMetricsSummary,'):
    require(trace, token, 'trace kind')
for token in (
    'event.kind != TraceEventKind.platformWindowFrameMetricsOutlier',
    'event.kind != TraceEventKind.platformWindowFrameMetricsSummary',
):
    require(debug, token, 'no diagnostic feedback Flutter frame')

for rel in (
    'tool/analyze_window_frame_pipeline_jank.py',
    'docs/adr/0298-android-window-frame-metrics-boundary.md',
    'docs/audits/dev319-android-window-frame-metrics-audit.md',
):
    if not (ROOT / rel).is_file():
        raise SystemExit(f'dev.319 missing artifact: {rel}')

docs = ''.join(read(path) for path in (
    'CHANGELOG.md', 'docs/ARCHITECTURE.md', 'docs/SPEC.md',
    'docs/IMPLEMENTATION_PLAN.md', 'docs/IMPLEMENTATION_STATUS.md',
    'docs/NEXT_CHAT_HANDOFF.md',
    'docs/adr/0297-static-webp-flutter-projection-composition-boundary.md',
    'docs/adr/0298-android-window-frame-metrics-boundary.md',
    'docs/audits/dev319-android-window-frame-metrics-audit.md',
))
for token in ('dev.318', 'FALSIFIED', '2096', '1521', '26.294ms', '76/97', 'FrameMetrics', 'unknown delay', 'droppedReports'):
    require(docs, token, 'device/governance evidence')

print('dev.319 Android Window FrameMetrics observation boundary: OK')
