#!/usr/bin/env python3
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.222 missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.222 forbidden {label}: {token}')

obs = read('packages/domain/lib/src/reader_observation.dart')
controller = read('packages/reader/lib/src/reader_controller.dart')
view = read('packages/reader/lib/src/reader_view.dart')
runtime = read('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
window = read('packages/pipeline/lib/src/role_window.dart')
pipeline = read('packages/pipeline/lib/src/pipeline_controller.dart')
pipeline_session = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
policy_test = read('packages/pipeline/test/pipeline_test.dart')
nav_test = read('packages/reader/test/reader_navigation_test.dart')
controls_test = read('apps/app/test/reader_controls_test.dart')

require(obs, 'scrubbing', 'explicit Reader interaction phase')
for token in (
    'bool _pageScrubbing = false;',
    'void beginPageScrub()',
    'void scrubToPage(int index)',
    'void endPageScrub(int index)',
    '_requestPage(index, forceRevision: true, animated: false);',
):
    require(controller, token, 'Reader-owned scrub navigation state')
for token in (
    'controller.pageScrubbing',
    'Interaction.scrubbing',
    '_emitObservation(',
):
    require(view, token, 'live viewport scrub projection')
for token in (
    'onScrubStarted: reader.beginPageScrub,',
    'onScrubbed: reader.scrubToPage,',
    'onScrubEnded: reader.endPageScrub,',
    'onChangeStart: pages <= 1 ? null : _start,',
    'onChanged: pages <= 1 ? null : _preview,',
    'onChangeEnd: pages <= 1 ? null : _commit,',
):
    require(runtime, token, 'slider-to-Reader scrub seam')
forbid(runtime, 'onChanged: reader.requestPage', 'slider bypass of scrub seam')
forbid(
    window,
    'if (observation.interaction == Interaction.scrubbing)',
    'interaction-owned scrub resource window',
)
for token in (
    'if (observation.direction == ReadingDirection.vertical)',
    'for (final coverage in observation.visibleCoverages)',
):
    require(window, token, 'viewport-owned visible foreground role')
require(pipeline, "'interaction': observation.interaction.name", 'scrub planning observability')
for token in (
    'void enqueueObservation(ReaderObs observation)',
    '_pendingObservation = observation;',
):
    require(pipeline_session, token, 'latest-wins Reader-to-Pipeline coalescing seam')
require(policy_test, 'slider scrub keeps the normal resource window', 'stable scrub demand regression')
require(
    policy_test,
    'adjacent scrub moves the 7/3 download window incrementally',
    'incremental scrub-window diff regression',
)
require(nav_test, 'page scrub updates navigation live and ends with a planning revision', 'Reader scrub lifecycle regression')
require(controls_test, 'Slider dragging is live Reader navigation', 'gesture live-navigation regression')

for rel in (
    'docs/adr/0203-live-reader-scrub-and-foreground-demand-boundary.md',
    'docs/audits/dev222-live-scrub-root-cause-audit.md',
    'docs/audits/dev222-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.222 missing governance: {rel}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
pub = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
android = re.search(r'^versionCode=(\d+)$', props, re.M)
if pub is None or int(pub.group(1)) < 222:
    raise SystemExit('dev.222 app version mismatch')
if android is None or int(android.group(1)) < 222:
    raise SystemExit('dev.222 Android version mismatch')
version_code = int(pub.group(1))
if version_code < 317:
    require(pipeline_session, 'scheduleMicrotask(() => _drainObservation(generation));', 'historical latest-wins microtask seam')
else:
    require(pipeline_session, 'Timer.run(() => _drainObservation(generation));', 'dev.317+ latest-wins ordinary-event-turn seam')
print('dev.222 live Reader scrub / viewport-owned demand boundary: OK')
