#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.308 missing {label}: {token}')

policy = read('packages/pipeline/lib/src/heuristic_policy.dart')
controller = read('packages/pipeline/lib/src/pipeline_controller.dart')
runtime = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
binding = read('packages/sessions/lib/src/reader_binding.dart')
view = read('packages/reader/lib/src/reader_view.dart')
pipeline_test = read('packages/pipeline/test/pipeline_test.dart')
reader_test = read('packages/reader/test/reader_navigation_test.dart')

for token in (
    'Set<int> runtimeLocalStaticPages = const <int>{}',
    'final localStaticReady =',
    'runtimeLocalStaticPages.contains(entry.key)',
    'runtimeAnimatedPages[entry.key] == false',
    'retainOutput: visibleStatic || localStaticReady',
):
    require(policy, token, 'bounded local static presentation')

pubspec = read('apps/app/pubspec.yaml')
version_match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
version = int(version_match.group(1)) if version_match is not None else 0
if version < 314 or version >= 316:
    require(policy, '!localStaticReady &&', 'dev.308 active-scroll local static exception')
else:
    if '!localStaticReady &&' in policy:
        raise SystemExit('dev.314-dev.315 must keep the fixed-position hidden local-static suppression experiment')

# Generic hidden static must remain deferred; the local exception may only
# remove that deferral after authoritative static/local facts exist.
for token in (
    'final deferHiddenVerticalStaticUpload =',
    '!primaryUpload',
    '!visibleStatic',
    '_verticalPresentationActive(observation.interaction)',
):
    require(policy, token, 'dev.295 generic hidden-static deferral')

for token in (
    'final Set<int> _runtimeLocalStaticPages = <int>{};',
    'bool? localPresentationReady',
    'runtimeLocalStaticPages: _runtimeLocalStaticPages',
):
    require(controller, token, 'Pipeline locality fact owner')
for token in (
    'final localPresentationReady = !animated &&',
    '_isDirectImmutableLocalUri(asset.uri)',
    'download?.residentBodyBacked == true',
    'localPresentationReady: localPresentationReady',
):
    require(runtime, token, 'runtime authoritative local/static classification')
require(binding, 'bool? localPresentationReady', 'binding locality projection')

for token in (
    'int? _lastVerticalVisibleMinIndex;',
    'final visibleMin = (_lastVerticalVisibleMinIndex ??',
    'if (_lastVerticalTravelDirection > 0)',
    'for (var index = visibleMax + 1; index < pages.length; index++)',
    'for (var index = 0; index < visibleMin; index++)',
    'geometryCorrectionTarget',
    '.restoreTop(oldAnchor)',
    "'visibleMinIndex': visibleMin",
    "'travelDirection': _lastVerticalTravelDirection",
):
    require(view, token, 'direction-aware active geometry preparation')
if 'jumpTo(correction)' in view or 'presentationExtentAt(' in view:
    raise SystemExit('dev.308 restored a superseded post-frame/presentation geometry workaround')

for token in (
    'runtimeLocalStaticPages: const <int>{6, 7}',
    'localPresentationReady: true',
    'hidden immediate next must not blit a static texture during active vertical scrolling',
):
    require(pipeline_test, token, 'local/static policy regression')
if 314 <= version < 316:
    require(
        pipeline_test,
        'local static evidence must not start hidden platform blits during active vertical scrolling',
        'dev.314 superseding active-scroll local static regression',
    )
else:
    require(
        pipeline_test,
        'a locally-backed authoritative static next page should be resident before it enters the viewport',
        'dev.308 local static pre-presentation regression',
    )
for token in (
    'reverse vertical scroll prepares incoming measured prefix without visible reflow',
    'an incoming lower-index page should use its measured extent before it enters the viewport',
):
    require(reader_test, token, 'reverse geometry regression')

profile = read('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart')
for token in (
    'forwardEncodedPages: 7',
    'backwardEncodedPages: 3',
    'forwardDecodePages: 2',
    'backwardDecodePages: 1',
):
    require(profile, token, 'frozen resource window')

all_docs = ''.join(read(path) for path in (
    'CHANGELOG.md',
    'docs/ARCHITECTURE.md',
    'docs/SPEC.md',
    'docs/IMPLEMENTATION_PLAN.md',
    'docs/IMPLEMENTATION_STATUS.md',
    'docs/NEXT_CHAT_HANDOFF.md',
    'docs/adr/0287-local-static-prepresentation-and-reverse-geometry-preparation.md',
    'docs/audits/dev308-local-static-prepresentation-and-reverse-geometry-audit.md',
))
for token in (
    '51ms', '52ms', '924.44', '1533.23', '1433.28',
    'localPresentationReady', 'visibleMin', 'geometryCorrectionTarget',
):
    require(all_docs, token, 'governed dev.308 evidence/boundary')

for path, limit in (
    ('docs/ARCHITECTURE.md', 420),
    ('docs/IMPLEMENTATION_PLAN.md', 180),
    ('docs/IMPLEMENTATION_STATUS.md', 220),
    ('docs/NEXT_CHAT_HANDOFF.md', 80),
):
    lines = read(path).splitlines()
    if len(lines) > limit:
        raise SystemExit(f'dev.308 documentation budget exceeded: {path} {len(lines)}>{limit}')

props = read('apps/app/android/zic-version.properties')
if version_match is None or version < 308:
    raise SystemExit('dev.308 app version missing/regressed')
if not re.search(rf'^versionCode={version}$', props, re.M):
    raise SystemExit('dev.308 Android version mismatch')

print('dev.308 local static pre-presentation / reverse geometry boundary: OK')
