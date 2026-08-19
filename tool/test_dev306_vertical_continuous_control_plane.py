#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.306 missing {label}: {token}')

runtime = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
binding = read('packages/sessions/lib/src/reader_binding.dart')
controller = read('packages/pipeline/lib/src/pipeline_controller.dart')
reader = read('packages/reader/lib/src/reader_controller.dart')
view = read('packages/reader/lib/src/reader_view.dart')
binding_test = read('packages/sessions/test/reader_binding_test.dart')
pipeline_test = read('packages/pipeline/test/vertical_visible_policy_test.dart')

for token in (
    '_sameVerticalControlObservation(',
    '_controlInteraction(Interaction interaction)',
    'Interaction.dragging ||',
    '_observationControlDirty',
    'if (!planChanged && !controlIdentityChanged)',
):
    require(runtime, token, 'vertical control-observation boundary')
for token in (
    'discretePages && observation.direction != ReadingDirection.vertical',
    '_sameViewportState(_playbackViewport, viewport)',
    '_cachedUploadRevision == plan.revision',
    'for (final page in chapter.pages) page.pageId: page.index',
):
    require(binding, token, 'viewport/playback control separation')
require(controller, "if (!_decodeTargetDirty && diff.isEmpty)",
        'empty semantic diff suppression')
require(reader, '_shouldTraceObservation(observation)',
        'Reader observation source sampling')
require(reader, '>= 250000', 'Reader observation heartbeat')
require(view, 'now - _lastVerticalLayoutSnapshotMicros < 500000',
        'coarse layout heartbeat')
require(view, 'now - _lastTransitionTraceMicros >= 250000',
        'transition source sampling')
require(binding_test,
        'vertical coverage-only motion does not resync playback control',
        'continuous playback regression')
require(pipeline_test,
        'far visible metadata does not create an empty scheduler revision',
        'empty semantic window regression')

# Continuous visual geometry must not be moved into another resource window or
# changed by the new boundary.
for forbidden in ('cacheExtent = 3', 'forwardDecodePages: 3', 'maxActive: 6'):
    if forbidden in runtime:
        raise SystemExit(f'dev.306 suspicious resource-policy expansion: {forbidden}')

all_docs = ''.join(read(path) for path in (
    'CHANGELOG.md',
    'docs/ARCHITECTURE.md',
    'docs/SPEC.md',
    'docs/IMPLEMENTATION_PLAN.md',
    'docs/IMPLEMENTATION_STATUS.md',
    'docs/NEXT_CHAT_HANDOFF.md',
    'docs/adr/0285-vertical-continuous-viewport-control-plane-separation.md',
    'docs/audits/dev306-vertical-continuous-control-plane-hotpath-audit.md',
))
for token in ('1,197', '132', 'control no-op', '250ms', '500ms'):
    require(all_docs, token, 'governed dev.306 evidence/boundary')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
if not re.search(r'^version: 0\.31\.0\+306$', pubspec, re.M):
    raise SystemExit('dev.306 app version mismatch')
if not re.search(r'^versionCode=306$', props, re.M):
    raise SystemExit('dev.306 Android version mismatch')

print('dev.306 vertical continuous viewport/control-plane separation: OK')
