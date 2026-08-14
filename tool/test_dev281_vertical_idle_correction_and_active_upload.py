#!/usr/bin/env python3
"""Guard dev.281 vertical idle-correction and active-upload ownership."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def req(ok: bool, message: str) -> None:
    if not ok:
        raise SystemExit(message)


def require(path: str, *needles: str) -> None:
    body = text(path)
    missing = [needle for needle in needles if needle not in body]
    req(not missing, f'{path} missing dev.281 contract: {missing}')


pub = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 281, 'dev.281 app version missing')
props = text('apps/app/android/zic-version.properties')
vm = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(vm is not None and int(vm.group(1)) >= 281, 'dev.281 Android version missing')

# dev.279 made the concrete source-watch session pointer mutable. A const
# constructor is therefore invalid Dart even though shallow source gates pass.
live = text('packages/sessions/lib/src/live_coordinator.dart')
binding = live[live.index('final class _SourceWatchBinding {'):live.index('\n}\n\nfinal class LiveCoordinator')]
req('DownloadSession session;' in binding, 'source-watch session pointer is no longer mutable')
req('const _SourceWatchBinding({' not in binding,
    'mutable _SourceWatchBinding still has an invalid const constructor')
req('_SourceWatchBinding({' in binding, 'source-watch binding constructor missing')

reader = text('packages/reader/lib/src/reader_view.dart')
for marker in (
    'final class _ReaderVerticalScrollPhysics extends ClampingScrollPhysics',
    'double? Function() geometryCorrectionTarget;',
    'double adjustPositionForNewDimensions({',
    'if (!isScrolling && target != null)',
    '.clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent)',
    'double? _pendingVerticalGeometryCorrection;',
    'nextRatios: pending,',
    'final nextGeometry = _verticalGeometry(ratios: nextRatios);',
    '_pendingVerticalGeometryCorrection = nextGeometry.restoreTop(anchor);',
    '_scheduleVerticalGeometryCorrectionClear();',
):
    req(marker in reader, f'atomic idle geometry correction missing: {marker}')

commit_start = reader.index('  void _schedulePendingVerticalRatioCommit()')
commit_end = reader.index('  void _resetVerticalCompositionCache()', commit_start)
commit = reader[commit_start:commit_end]
req('_verticalController.jumpTo(' not in commit,
    'ratio idle commit still performs a notification-producing jumpTo')
req('_preserveVerticalAnchor(' in commit and 'nextRatios: pending,' in commit,
    'pending ratio commit does not request layout-time anchor correction')

physics_start = reader.index('final class _ReaderVerticalScrollPhysics')
physics_end = reader.index('\nfinal class ReaderView', physics_start)
physics = reader[physics_start:physics_end]
req('super.adjustPositionForNewDimensions(' in physics,
    'custom vertical physics does not preserve normal scroll dimension behavior')

policy = text('packages/pipeline/lib/src/heuristic_policy.dart')
for marker in (
    'final deferVerticalNext2Upload =',
    'observation.direction == ReadingDirection.vertical',
    '!visibleStatic',
    'role == PageRole.next2',
    '_verticalPresentationActive(observation.interaction)',
    'if ((primaryUpload || staticWarm) && !deferVerticalNext2Upload)',
    'Interaction.dragging ||',
    'Interaction.scrolling ||',
    'Interaction.settling => true,',
):
    req(marker in policy, f'vertical active next2 upload deferral missing: {marker}')

require(
    'packages/reader/test/reader_navigation_test.dart',
    'vertical measured ratios stay frozen until active scrolling is idle',
    'idle geometry correction must not expose the new extents at the old pixels before anchor correction',
    'an async ratio commit above the viewport must preserve the visible page identity',
)
require(
    'packages/pipeline/test/pipeline_test.dart',
    'vertical active scroll keeps next2 decode warm but defers its hidden static upload',
    'active vertical scrolling must keep next2 decode warm',
    'a hidden next2 static texture must not blit while vertical presentation is active',
    'next2 texture warming resumes once the vertical viewport is idle',
)

for path in (
    'docs/adr/0260-vertical-idle-layout-correction-and-active-texture-deferral.md',
    'docs/audits/dev281-release-jitter-and-dart-compile-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.281 governance file: {path}')

require('docs/ARCHITECTURE.md', 'layout-time scroll correction', 'non-visible next2')
require('docs/SPEC.md', 'layout-time correction', 'next2 texture upload')
require('docs/IMPLEMENTATION_STATUS.md', 'dev.281', '10.432')
require('docs/IMPLEMENTATION_PLAN.md', 'dev.281', 'slow-release', 'ballistic')
require('docs/NEXT_CHAT_HANDOFF.md', 'dev.281', '10.432', 'next2')
require('CHANGELOG.md', '0.31.0-dev.281', 'layout-time correction')

# Frozen resource and lifecycle boundaries remain visible in the handoff.
require('docs/NEXT_CHAT_HANDOFF.md', 'previous3/next7', 'normal5+current reserved1', 'sealed-source-generation-preserved')

print('PASS: dev.281 vertical idle correction + active next2 upload deferral')
