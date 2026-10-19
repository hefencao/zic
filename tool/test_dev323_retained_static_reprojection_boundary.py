#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.323 missing {label}: {token}')


def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.323 forbidden {label}: {token}')


pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
match = re.search(r'^version: \d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)$', pubspec, re.M)
if match is None or int(match.group(1)) < 323:
    raise SystemExit('dev.323+ version mismatch')
version = int(match.group(1))
if not re.search(rf'^versionCode={version}$', props, re.M):
    raise SystemExit('dev.323 Android version mismatch')

session = read('packages/sessions/lib/src/upload_session.dart')
registry = read('packages/sessions/lib/src/upload_registry.dart')
output = read('packages/pipeline_runtime/lib/src/pipeline_page_output.dart')
regression = read('packages/sessions/test/upload_session_test.dart')
analyzer = read('tool/analyze_resident_static_reprojection_jank.py')

for token in (
    'bool reusePresentedStatic(PresentClaim claim)',
    'identical(_slot?.frame, claim.frame)',
    'claim.released',
    'animation.frameCount > 1',
    'claim.frame.duration.inMicroseconds > 0',
    'lastPresentationTiming',
):
    require(session, token, 'owner-side static reuse guard')

require(registry, 'reusePresentedStatic(DecodeId id, PresentClaim claim)', 'registry projection')
for token in (
    'final reusedStatic = _uploads.reusePresentedStatic(identity, claim);',
    'if (!reusedStatic) {',
    'await _uploads.present(identity, claim);',
):
    require(output, token, 'page-output reuse path')

for token in (
    'retained static output reuses prior presentation without re-presenting',
    'expect(upload.reusePresentedStatic(first!), isFalse);',
    'expect(upload.reusePresentedStatic(revisit!), isTrue);',
    'expect(uploader.outputs.single.presented, 1);',
):
    require(regression, token, 'direct UploadSession regression')

for token in (
    'flip_exactly_two',
    'platformResidentReuse',
    'direction-flip-resident-static-representation',
):
    require(analyzer, token, 'resident-static analyzer')

for rel in (
    'docs/archive/adr/0301-retained-static-reprojection-boundary.md',
    'docs/archive/audits/dev323-retained-static-reprojection-audit.md',
):
    if not (ROOT / rel).is_file():
        raise SystemExit(f'dev.323 missing artifact: {rel}')

# The fast path itself must not widen presentation retention or introduce a
# new rendering/scheduling owner.
method_match = re.search(
    r'bool reusePresentedStatic\(PresentClaim claim\) \{(.*?)\n  \}\n\n  Future<void> present',
    session,
    re.S,
)
if method_match is None:
    raise SystemExit('dev.323 reusePresentedStatic method block not found')
method = method_match.group(1)
for token in ('scheduleFrame(', 'jumpTo(', 'animateTo(', 'currentPageIndex'):
    forbid(method, token, 'unrelated scheduling/retention behavior')

trace = Path('/mnt/data/zic-debug-trace-2026-08-20T03-35-56.jsonl')
if trace.is_file():
    out = subprocess.check_output(
        ['python3', str(ROOT / 'tool/analyze_resident_static_reprojection_jank.py'), str(trace)],
        text=True,
    )
    for token in (
        'task_failed=0',
        'flip_exactly_two=26/26',
        'associated=52',
        'per_flip_median_us=1886',
        'verdict=direction-flip-resident-static-representation',
    ):
        require(out, token, 'dev.322 valid baseline')

print('dev.323 retained static re-projection boundary: OK')
