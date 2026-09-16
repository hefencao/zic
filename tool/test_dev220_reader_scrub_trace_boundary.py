#!/usr/bin/env python3
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.220 missing {label}: {token}')


def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.220 forbidden {label}: {token}')


runtime = read('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
reader_controls_test = read('apps/app/test/reader_controls_test.dart')
app_smoke_test = read('apps/app/test/app_smoke_test.dart')
binding = read('packages/sessions/lib/src/reader_binding.dart')
pipe = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
transfer_runtime = read('packages/downloads/lib/src/composition_download_transfer_runtime.dart')
media_test = read('packages/pipeline_runtime/test/media_runtime_ownership_test.dart')
architecture = read('docs/ARCHITECTURE.md')
spec = read('docs/SPEC.md')
plan = read('docs/IMPLEMENTATION_PLAN.md')
status = read('docs/IMPLEMENTATION_STATUS.md')
handoff = read('docs/NEXT_CHAT_HANDOFF.md')
changelog = read('CHANGELOG.md')

for token in (
    'final class _ReaderPageScrubber extends StatefulWidget',
    'int? _previewIndex;',
    'onChangeStart: pages <= 1 ? null : _start,',
    'onChanged: pages <= 1 ? null : _preview,',
    'onChangeEnd: pages <= 1 ? null : _commit,',
    '_previewIndex ?? widget.requestedIndex ?? widget.currentIndex',
):
    require(runtime, token, 'scrub presentation/navigation boundary')

scrubber = runtime[runtime.index('final class _ReaderPageScrubber'):]
forbid(scrubber, 'onChanged: reader.requestPage', 'UI bypassing Reader scrub navigation API')
for token in (
    'Slider dragging is live Reader navigation',
    "find.byKey(const ValueKey<String>('reader-page-rotation:2'))",
    'await gesture.up();',
    'slider.onChangeEnd!(2);',
):
    require(reader_controls_test, token, 'real gesture scrub regression')
require(app_smoke_test, 'slider.onChangeEnd!(1);', 'smoke test scrub completion')

accept_match = re.search(r'^  \w+ accept\(ReaderObs observation\) \{', binding, re.M)
if accept_match is None:
    raise SystemExit('dev.220 ReaderBinding accept method is missing')
accept_start = accept_match.start()
accept_end = binding.index('\n  bool classifyPage', accept_start)
accept = binding[accept_start:accept_end]
for token in (
    'final viewport = _viewportResolver.resolve(',
    '_viewport = viewport;',
    'try {',
    'pipeline.accept(observation);',
    '} finally {',
):
    require(accept, token, 'Reader-local viewport/playback boundary')
current_version = int(re.search(r'^version: 0\.31\.0\+(\d+)$',
                                read('apps/app/pubspec.yaml'), re.M).group(1))
if current_version >= 306:
    require(accept, '_syncPlayback(viewport);',
            'dev.306 semantic playback boundary')
    require(binding, '_playback.syncPlayback(viewport, _uploadIds(pipeline.currentPlan));',
            'playback implementation')
else:
    require(accept, '_playback.syncPlayback(viewport, _uploadIds(pipeline.currentPlan));',
            'Reader-local viewport/playback boundary')
if accept.index('_viewport = viewport;') > accept.index('pipeline.accept(observation);'):
    raise SystemExit('dev.220 viewport fact must be committed before demand reconcile')

for token in (
    'final Map<TraceSink, int> _sinks = <TraceSink, int>{};',
    '_sinks.update(sink, (count) => count + 1, ifAbsent: () => 1);',
    'for (final sink in _sinks.keys.toList(growable: false))',
    'required TraceSink consumerTraceSink,',
    'TraceSink? localPhysicalTraceSink,',
    'TraceSink? sharedPhysicalTraceSink,',
):
    require(transfer_runtime, token, 'physical trace composition ownership')
for token in (
    'consumerTraceSink: trace,',
    'sharedPhysicalTraceSink: _sharedTraceSink,',
    'trace = traceSink ?? const NoopTraceSink();',
):
    require(pipe, token, 'Reader physical trace projection')
forbid(pipe, '_memoryTrace', 'unconsumed per-Reader physical trace copy')
forbid(transfer_runtime, 'final Set<TraceSink> _sinks', 'unrefcounted physical trace fan-out')
require(media_test, 'shared physical trace sink emits each demand once across Readers', 'cross-Reader trace fan-out regression')
require(media_test, "expect(physicalDemandCount('reader:trace-reader-a'), 1);", 'Reader A trace de-dup assertion')
require(media_test, "expect(physicalDemandCount('reader:trace-reader-b'), 1);", 'Reader B trace de-dup assertion')

all_docs = architecture + spec + plan + status + handoff + changelog
for token in ('scrub', 'physical trace', 'Reader'):
    if token.lower() not in all_docs.lower():
        raise SystemExit(f'dev.220 governance missing ownership term: {token}')
for rel in (
    'docs/adr/0201-reader-scrub-intent-and-physical-trace-fanout-boundary.md',
    'docs/audits/dev220-navigation-scrub-trace-fanout-root-cause-audit.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.220 governance file missing: {rel}')

pubspec = read('apps/app/pubspec.yaml')
version_props = read('apps/app/android/zic-version.properties')
pub_match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
android_match = re.search(r'^versionCode=(\d+)$', version_props, re.M)
if pub_match is None or int(pub_match.group(1)) < 220:
    raise SystemExit('dev.220+ app version mismatch')
if android_match is None or int(android_match.group(1)) < 220:
    raise SystemExit('dev.220+ Android version mismatch')

print('dev.220 Reader scrub / physical trace fan-out boundary: OK')
