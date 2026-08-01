#!/usr/bin/env python3
"""Static guard for duplicate policy submissions and the vertical test regression."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
pipeline = (ROOT / 'packages/pipeline/lib/src/pipeline_controller.dart').read_text(
    encoding='utf-8'
)
for token in (
    'if (_sameRoles(_previousRoles, window.roles))',
    '_previousRoles = Map<int, PageRole>.unmodifiable(window.roles)',
    'bool _sameRoles(Map<int, PageRole>? previous, Map<int, PageRole> next)',
):
    if token not in pipeline:
        raise SystemExit(f'pipeline stability contract is missing: {token}')

binding = (ROOT / 'packages/sessions/lib/src/reader_binding.dart').read_text(
    encoding='utf-8'
)
for token in (
    'pipeline.accept(observation);\n    _syncViewport(observation);',
    '_playback.syncPlayback(viewport, _uploadIds(pipeline.currentPlan))',
):
    if token not in binding:
        raise SystemExit(f'viewport/demand separation contract is missing: {token}')

if 'for (final id in plan.uploads.keys)' not in binding:
    raise SystemExit('viewport playback must bind only current/transition upload identities')
if '...plan.decodes.keys' in binding:
    raise SystemExit('viewport playback must not create upload sessions for decode-only pages')

reader_binding_test = (
    ROOT / 'packages/sessions/test/reader_binding_test.dart'
).read_text(encoding='utf-8')
if "unchanged demand roles still update viewport playback" not in reader_binding_test:
    raise SystemExit('viewport updates are not covered independently from demand roles')

geometry_test = (
    ROOT / 'packages/reader/test/vertical_reader_geometry_test.dart'
).read_text(encoding='utf-8')
for token in (
    'ReaderVerticalGeometry(',
    'readerVerticalPageGap',
    'boundsAt(1)',
    'anchorForTop(top)',
    'restoreTop(anchor)',
):
    if token not in geometry_test:
        raise SystemExit(f'pure vertical geometry regression coverage is missing: {token}')

reader_test = (ROOT / 'packages/reader/test/reader_navigation_test.dart').read_text(
    encoding='utf-8'
)
for unstable in (
    '_pumpUntilCondition',
    'Future.delayed(',
    'gap.evaluate().toList',
    'tester.widget<SizedBox>(gap)',
):
    if unstable in reader_test:
        raise SystemExit(f'vertical Reader widget tests restored timing/lazy-child coupling: {unstable}')

print('Pipeline demand stability and vertical test contract: OK')
