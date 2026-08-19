#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.307 missing {label}: {token}')

controller = read('packages/reader/lib/src/reader_controller.dart')
view = read('packages/reader/lib/src/reader_view.dart')
runtime = read('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
trace = read('packages/telemetry/lib/src/trace.dart')
debug = read('apps/app/lib/debug_trace.dart')
test = read('packages/reader/test/reader_controller_test.dart')

for token in (
    'final ValueNotifier<int> _currentIndexNotifier;',
    'ValueListenable<int> get currentIndexListenable',
    '_currentIndexNotifier.value = _currentIndex;',
):
    require(controller, token, 'narrow current projection')
report = controller[controller.index('void report(ReaderObs observation)'):controller.index('bool _shouldTraceObservation')]
if 'notifyListeners();' in report:
    raise SystemExit('dev.307 current report still wakes broad command notifier')

for token in (
    'late final ValueNotifier<int> _verticalKeepAliveCenter;',
    'keepAliveCenter: _verticalKeepAliveCenter',
    '(widget.index - widget.keepAliveCenter.value).abs() <= 7',
    '_handleCurrentIndexChanged()',
    '_handleKeepAliveCenterChanged()',
    'TraceEventKind.scrollCadenceOutlier',
    'gapMicros <= 20000',
):
    require(view, token, 'Reader current/keepAlive/cadence boundary')
if '(widget.index - controller.currentIndex).abs() <= 7' in view:
    raise SystemExit('dev.307 keepAlive still follows every current crossing')

for token in (
    'created.currentIndexListenable.addListener(_handleReaderProgress)',
    'reader.currentIndexListenable.removeListener(_handleReaderProgress)',
    'valueListenable: reader.currentIndexListenable',
):
    require(runtime, token, 'narrow ReaderRuntime current consumers')
require(trace, 'scrollCadenceOutlier,', 'cadence trace kind')
require(debug, 'event.kind != TraceEventKind.scrollCadenceOutlier',
        'cadence diagnostic no-frame boundary')
for token in ('commandNotifications', 'currentNotifications',
              'current projection must not wake command consumers'):
    require(test, token, 'ReaderController regression')

for path, limit in (
    ('docs/ARCHITECTURE.md', 420),
    ('docs/IMPLEMENTATION_PLAN.md', 180),
    ('docs/IMPLEMENTATION_STATUS.md', 220),
    ('docs/NEXT_CHAT_HANDOFF.md', 80),
):
    lines = read(path).splitlines()
    if len(lines) > limit:
        raise SystemExit(f'dev.307 documentation budget exceeded: {path} {len(lines)}>{limit}')

all_docs = ''.join(read(path) for path in (
    'CHANGELOG.md',
    'docs/ARCHITECTURE.md',
    'docs/SPEC.md',
    'docs/IMPLEMENTATION_PLAN.md',
    'docs/IMPLEMENTATION_STATUS.md',
    'docs/NEXT_CHAT_HANDOFF.md',
    'docs/adr/0286-reader-position-command-and-scroll-lifecycle-boundary.md',
    'docs/audits/dev307-reader-current-boundary-build-jank-audit.md',
))
for token in ('13.8ms', '29.5ms', '32.2ms', 'scrollCadenceOutlier',
              'currentIndexListenable', 'current±7'):
    require(all_docs, token, 'governed dev.307 evidence/boundary')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
if not re.search(r'^version: 0\.31\.0\+307$', pubspec, re.M):
    raise SystemExit('dev.307 app version mismatch')
if not re.search(r'^versionCode=307$', props, re.M):
    raise SystemExit('dev.307 Android version mismatch')

print('dev.307 Reader position/command/lifecycle boundary: OK')
