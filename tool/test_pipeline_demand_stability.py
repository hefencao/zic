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

reader_test = (ROOT / 'packages/reader/test/reader_navigation_test.dart').read_text(
    encoding='utf-8'
)
case = reader_test.split(
    "testWidgets('vertical mode uses proportional continuous pages and stitch gap'",
    1,
)[1].split("testWidgets('vertical mode adopts measured media geometry", 1)[0]
for token in (
    'final gapElements = gap.evaluate().toList(growable: false)',
    'expect(gapElements, hasLength(1))',
    'gapElements.first.widget as SizedBox',
):
    if token not in case:
        raise SystemExit(f'vertical navigation regression test is missing: {token}')
if 'tester.widget<SizedBox>(gap)' in case or '.single' in case:
    raise SystemExit('vertical navigation test still assumes a lazy child exists')

print('Pipeline demand stability and vertical test contract: OK')
