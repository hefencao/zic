#!/usr/bin/env python3
"""Guard dev.200 deferred catchup memory and two-tier cost policy."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
LIVE = (ROOT / 'packages/sessions/lib/src/live_coordinator.dart').read_text(encoding='utf-8')
TEST = (ROOT / 'packages/sessions/test/live_coordinator_test.dart').read_text(encoding='utf-8')
ARCH = (ROOT / 'docs/ARCHITECTURE.md').read_text(encoding='utf-8')
SPEC = (ROOT / 'docs/SPEC.md').read_text(encoding='utf-8')
STATUS = (ROOT / 'docs/IMPLEMENTATION_STATUS.md').read_text(encoding='utf-8')
HANDOFF = (ROOT / 'docs/NEXT_CHAT_HANDOFF.md').read_text(encoding='utf-8')
CHANGELOG = (ROOT / 'CHANGELOG.md').read_text(encoding='utf-8')

for token in (
    'final Map<DownloadId, int> _downloadDeferredAtLength = <DownloadId, int>{};',
    'deferredAtLength == session.committedLength',
    'final preserveDeferred =',
    'session.state == DownloadState.idle',
    'const largePrefixBytes = 1024 * 1024;',
    'const veryLargePrefixBytes = 8 * 1024 * 1024;',
    'const foregroundAdjacentPriorityFloor = 820;',
    'const visibleTransitionPriorityFloor = 900;',
    'priority >= visibleTransitionPriorityFloor',
):
    if token not in LIVE:
        raise SystemExit(f'dev.200 coordinator contract missing: {token}')

for token in (
    'readdedBackground',
    'diff: DemandDiff.between(detached, readdedBackground)',
    'expect(transport.requests, hasLength(1));',
    'very large unsupported-range partial waits for transition demand',
    "role: PageRole.next,\n      priority: 820",
    "role: PageRole.transition,\n      priority: 900",
):
    if token not in TEST:
        raise SystemExit(f'dev.200 behavior regression missing: {token}')

# The catchup admission decision may depend only on preserved byte cost and
# scheduler-owned priority.  Existing LiveCoordinator playback collaborators are
# outside this block and must not be mistaken for a new admission dependency.
policy_match = re.search(
    r'bool _allowsCostlyFullBodyCatchup\(\{.*?^  \}',
    LIVE,
    re.MULTILINE | re.DOTALL,
)
if policy_match is None:
    raise SystemExit('dev.200 catchup admission policy block missing')
policy = policy_match.group(0)
for forbidden in (
    'duplicatePrefixBytes',
    'sourceHostRemoteIpHash',
    'sourceHostHttpVersion',
    'sourceRhttp',
    'decodeState',
    'frame',
    'playback',
):
    if forbidden in policy:
        raise SystemExit(
            f'dev.200 catchup admission illegally consumes non-cost input: {forbidden}'
        )

for body, name in ((ARCH, 'architecture'), (SPEC, 'spec')):
    for token in ('1MiB', '8MiB', '820', '900', 'committedLength'):
        if token not in body.replace(' ', ''):
            raise SystemExit(f'dev.200 stable contract missing from {name}: {token}')

pubspec = (ROOT / 'apps/app/pubspec.yaml').read_text(encoding='utf-8')
properties = (ROOT / 'apps/app/android/zic-version.properties').read_text(encoding='utf-8')
app = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.MULTILINE)
android = re.search(r'^versionCode=(\d+)$', properties, re.MULTILINE)
if app is None or int(app.group(1)) < 200:
    raise SystemExit('dev.200-or-newer app build missing')
if android is None or int(android.group(1)) < 200:
    raise SystemExit('dev.200-or-newer Android version missing')

for body, name in ((STATUS, 'status'), (HANDOFF, 'handoff'), (CHANGELOG, 'changelog')):
    if 'dev.200' not in body:
        raise SystemExit(f'dev.200 missing from {name}')

for path in (
    ROOT / 'docs/adr/0181-deferred-catchup-memory-and-two-tier-cost.md',
    ROOT / 'docs/audits/dev200-dev199-defer-lifetime-two-tier-cost-audit.md',
    ROOT / 'docs/audits/dev200-validation-results.md',
):
    if not path.exists():
        raise SystemExit(f'dev.200 release document missing: {path.relative_to(ROOT)}')

adr180 = (ROOT / 'docs/adr/0180-cost-aware-full-body-catchup-admission.md').read_text(encoding='utf-8')
if 'Superseded by ADR 0181' not in adr180:
    raise SystemExit('ADR0180 supersession marker missing')

print('dev.200 deferred catchup memory and two-tier cost: OK')
