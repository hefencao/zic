#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.313 missing {label}: {token}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
if match is None or int(match.group(1)) < 313:
    raise SystemExit('dev.313 app version missing/regressed')
version = int(match.group(1))
if not re.search(rf'^versionCode={version}$', props, re.M):
    raise SystemExit('dev.313 Android version mismatch')

native = read('packages/reader_runtime/android/src/main/kotlin/dev/zic/readerruntime/ReaderRuntimePlugin.kt')
cadence = read('packages/reader_runtime/lib/src/flutter_reader_platform_frame_cadence.dart')
runtime = read('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
trace = read('packages/telemetry/lib/src/trace.dart')
debug = read('apps/app/lib/debug_trace.dart')

require(native, 'import android.view.Choreographer', 'correct Choreographer package')
if 'android.os.Choreographer' in native:
    raise SystemExit('dev.313 restored invalid android.os.Choreographer import')
for token in (
    'recordFrameGap(priorFrame, frameTimeNanos, frameGapMicros)',
    'drainFrameCadenceSummary',
    'frameIntervalCount',
    'gapLt10msCount',
    'gap14To18msCount',
    'gap25To35msCount',
    'FRAME_GAP_BIN_COUNT = 7',
):
    require(native, token, 'all-frame native cadence summary')
for token in (
    "'drainFrameCadenceSummary'",
    'TraceEventKind.platformFrameCadenceSummary',
    "'frameIntervalCount'",
    "'gapLt10msCount'",
    "'gap14To18msCount'",
):
    require(cadence, token, 'Dart cadence summary projection')
require(trace, 'platformFrameCadenceSummary,', 'summary trace kind')
require(debug, 'event.kind != TraceEventKind.platformFrameCadenceSummary', 'no summary feedback frame')

if 'FlutterReaderPlatformFrameRatePolicy' in runtime:
    raise SystemExit('dev.313 production Reader still activates rejected ARR intervention')

# dev.313 is deliberately observation-only. Do not turn the diagnosis into a
# frame-rate/scroll behavior workaround before Java-vs-Flutter cadence splits.
product = native + cadence + runtime
for forbidden in (
    'setFrameRateBoostOnTouchEnabled(',
    'setRequestedFrameRate(',
    'preferredRefreshRate =',
    'Surface.setFrameRate(',
    'jumpTo(',
    'animateTo(',
    'scheduleFrame(',
    'resamplingEnabled',
    'samplingOffset',
):
    if forbidden in product:
        raise SystemExit(f'dev.313 observation boundary leaked behavior: {forbidden}')

for path in (
    'docs/adr/0292-platform-vsync-effective-cadence-boundary.md',
    'docs/audits/dev313-platform-vsync-effective-cadence-audit.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'dev.313 artifact missing: {path}')

docs = ''.join(read(path) for path in (
    'CHANGELOG.md', 'docs/ARCHITECTURE.md', 'docs/SPEC.md',
    'docs/IMPLEMENTATION_PLAN.md', 'docs/IMPLEMENTATION_STATUS.md',
    'docs/NEXT_CHAT_HANDOFF.md',
    'docs/adr/0291-vertical-reader-android-arr-boundary.md',
    'docs/adr/0292-platform-vsync-effective-cadence-boundary.md',
    'docs/audits/dev313-platform-vsync-effective-cadence-audit.md',
))
for token in (
    'displayHasArrSupport=false', 'displayHasArrSupport=true',
    '16.478ms', '16.124ms', '28.606ms',
    'platformFrameCadenceSummary', '8.3ms', '16.7ms',
    'observation-only', 'ARR',
):
    require(docs, token, 'governed cross-device cadence boundary')

print('dev.313 platform-vsync effective cadence boundary: OK')
