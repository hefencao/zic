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
physics_target_marker = (
    'if (target != null)' if int(m.group(1)) >= 308
    else 'if (!isScrolling && target != null)'
)
for marker in (
    'final class _ReaderVerticalScrollPhysics extends ClampingScrollPhysics',
    'double? Function() geometryCorrectionTarget;',
    'double adjustPositionForNewDimensions({',
    physics_target_marker,
    '.clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent)',
    'double? _pendingVerticalGeometryCorrection;',
    'nextRatios: pending,',
    'final nextGeometry = _verticalGeometry(ratios: nextRatios);',
    '_pendingVerticalGeometryCorrection = nextGeometry.restoreTop(anchor);',
    '_scheduleVerticalGeometryCorrectionClear();',
):
    req(marker in reader, f'atomic idle geometry correction missing: {marker}')
if int(m.group(1)) >= 308:
    for marker in (
        'if (_lastVerticalTravelDirection < 0 &&',
        'for (var index = 0; index < visibleMin; index++)',
        '.restoreTop(oldAnchor)',
    ):
        req(marker in reader, f'dev.308 selective active prefix correction missing: {marker}')

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
interaction_policy = text('packages/pipeline/lib/src/interaction_policy.dart')
if int(m.group(1)) >= 327:
    policy_markers = (
        'final externalStatic =',
        'runtimeExternalStaticPages.contains(entry.key)',
        'final deadlineStaticPreupload =',
        'role == PageRole.next ||',
        'role == PageRole.next2 ||',
        'role == PageRole.previous;',
        'final deferHiddenVerticalNativeStaticUpload =',
        'observation.direction == ReadingDirection.vertical',
        'staticWarm &&',
        '!primaryUpload',
        '!visibleStatic',
        '!deadlineStaticPreupload &&',
        '!localStaticReady',
        '!externalStatic',
        'isPresentationMotionInteraction(observation.interaction)',
        'observation.targetCoverage?.pageIndex == entry.key',
        '(role == PageRole.next || role == PageRole.previous)',
        'if (primaryUpload || staticWarm || pagedTargetPreupload) {',
        'prepareOutput: !deferHiddenVerticalNativeStaticUpload &&',
    )
elif int(m.group(1)) == 315:
    policy_markers = (
        'final encodedFlutterPresentation =',
        'runtimeWebpPages.contains(entry.key)',
        'runtimeAnimatedPages[entry.key] != true',
        'final deferHiddenVerticalStaticUpload =',
        'observation.direction == ReadingDirection.vertical',
        'staticWarm &&',
        '!primaryUpload',
        '!visibleStatic',
        'isPresentationMotionInteraction(observation.interaction)',
        '!encodedFlutterPresentation',
        '!deferHiddenVerticalStaticUpload',
    )
elif int(m.group(1)) >= 295:
    policy_markers = (
        'final deferHiddenVerticalStaticUpload =',
        'observation.direction == ReadingDirection.vertical',
        'staticWarm &&',
        '!primaryUpload',
        '!visibleStatic',
        'isPresentationMotionInteraction(observation.interaction)',
        'observation.targetCoverage?.pageIndex == entry.key',
        '(role == PageRole.next || role == PageRole.previous)',
        'if ((primaryUpload || staticWarm || pagedTargetPreupload) &&',
        '!deferHiddenVerticalStaticUpload',
    )
else:
    policy_markers = (
        'final deferVerticalNext2Upload =',
        'observation.direction == ReadingDirection.vertical',
        '!visibleStatic',
        'role == PageRole.next2',
        'isPresentationMotionInteraction(observation.interaction)',
        'if ((primaryUpload || staticWarm) && !deferVerticalNext2Upload)',
    )
for marker in policy_markers:
    req(marker in policy, f'vertical active static upload deferral missing: {marker}')
interaction_markers = (
    (
        'enum ResourceInteractionPhase',
        'ResourceInteractionPhase resourceInteractionPhase(Interaction interaction)',
        'Interaction.dragging ||',
        'Interaction.scrolling ||',
        'Interaction.settling => ResourceInteractionPhase.motion,',
        'bool isPresentationMotionInteraction(Interaction interaction)',
        'ResourceInteractionPhase.motion;',
    )
    if int(m.group(1)) >= 327
    else (
        'bool isPresentationMotionInteraction(Interaction interaction)',
        'Interaction.dragging ||',
        'Interaction.scrolling ||',
        'Interaction.settling => true,',
    )
)
for marker in interaction_markers:
    req(marker in interaction_policy, f'presentation-motion vocabulary missing: {marker}')

require(
    'packages/reader/test/reader_navigation_test.dart',
    'vertical measured ratios stay frozen until active scrolling is idle',
    'idle geometry correction must not expose the new extents at the old pixels before anchor correction',
    'an async ratio commit above the viewport must preserve the visible page identity',
)
if int(m.group(1)) >= 327:
    require(
        'packages/pipeline/test/pipeline_test.dart',
        'vertical active scroll preuploads native static deadline roles but defers far',
        'active vertical scrolling must keep next2 decode warm',
        'the existing next2 decode deadline must also own one prepared static output during active scroll',
        'active motion retains far upload identity but must not start speculative presentation work',
        'an exact external-static next page must retain staged first-frame work while the viewport is moving',
        'far speculative texture warming expands only after the vertical viewport is idle',
    )
else:
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

if int(m.group(1)) >= 327:
    require(
        'docs/ARCHITECTURE.md',
        'layout-time scroll correction',
        'non-visible `far/near` speculative static output',
        '`prepareOutput=false`',
        '`next/next2/previous`',
        'UploadLane',
        'external-static',
    )
    require(
        'docs/SPEC.md',
        'layout-time correction',
        '`far/near` speculative role defer新的native presentation work',
        '`prepareOutput=false`',
        '`next/next2/previous`',
        'FrameBudgeter',
    )
elif int(m.group(1)) == 315:
    require('docs/ARCHITECTURE.md', 'layout-time scroll correction', 'compressed bytes')
    require('docs/SPEC.md', 'layout-time correction', 'compressed bytes')
elif int(m.group(1)) >= 295:
    require('docs/ARCHITECTURE.md', 'layout-time scroll correction', 'non-visible speculative static texture upload')
    require('docs/SPEC.md', 'layout-time correction', 'speculative static page MUST defer UploadDemand')
else:
    require('docs/ARCHITECTURE.md', 'layout-time scroll correction', 'non-visible next2')
    require('docs/SPEC.md', 'layout-time correction', 'next2 texture upload')
if int(m.group(1)) >= 327:
    require(
        'docs/IMPLEMENTATION_STATUS.md',
        'native static只继续defer `far/near` speculative upload',
        '`next/next2/previous`',
    )
else:
    require('docs/IMPLEMENTATION_STATUS.md', 'vertical hidden-upload规则不变', 'anchor/geometry rebuild')
require('docs/IMPLEMENTATION_PLAN.md', 'dev.281', 'slow-release', 'ballistic')
require('CHANGELOG.md', '0.31.0-dev.281', 'layout-time correction')

print('PASS: dev.281 vertical idle correction + active next2 upload deferral')
