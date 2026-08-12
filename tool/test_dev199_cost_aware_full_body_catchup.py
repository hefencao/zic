#!/usr/bin/env python3
"""Guard dev.199 cost-aware full-body catchup admission."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
JOB = (ROOT / 'packages/sessions/lib/src/download_job.dart').read_text(encoding='utf-8')
SESSION = (ROOT / 'packages/sessions/lib/src/download_session.dart').read_text(encoding='utf-8')
LIVE = (ROOT / 'packages/sessions/lib/src/live_coordinator.dart').read_text(encoding='utf-8')
OWNER_PATH = ROOT / 'packages/sessions/lib/src/download_transfer_owner.dart'
OWNER = OWNER_PATH.read_text(encoding='utf-8') if OWNER_PATH.exists() else LIVE
RANK_POLICY = (ROOT / 'packages/sessions/lib/src/transfer_rank_policy.dart').read_text(encoding='utf-8') if (ROOT / 'packages/sessions/lib/src/transfer_rank_policy.dart').exists() else ''
JOB_TEST = (ROOT / 'packages/sessions/test/download_job_test.dart').read_text(encoding='utf-8')
LIVE_TEST = (ROOT / 'packages/sessions/test/live_coordinator_test.dart').read_text(encoding='utf-8')
ARCH = (ROOT / 'docs/ARCHITECTURE.md').read_text(encoding='utf-8')
SPEC = (ROOT / 'docs/SPEC.md').read_text(encoding='utf-8')
STATUS = (ROOT / 'docs/IMPLEMENTATION_STATUS.md').read_text(encoding='utf-8')
HANDOFF = (ROOT / 'docs/NEXT_CHAT_HANDOFF.md').read_text(encoding='utf-8')
CHANGELOG = (ROOT / 'CHANGELOG.md').read_text(encoding='utf-8')

pubspec = (ROOT / 'apps/app/pubspec.yaml').read_text(encoding='utf-8')
properties = (ROOT / 'apps/app/android/zic-version.properties').read_text(encoding='utf-8')
app = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.MULTILINE)
android = re.search(r'^versionCode=(\d+)$', properties, re.MULTILINE)
if app is None or int(app.group(1)) < 199:
    raise SystemExit('dev.199-or-newer app build missing')
if android is None or int(android.group(1)) < 199:
    raise SystemExit('dev.199-or-newer Android version missing')
build = int(app.group(1))

for token in (
    'typedef FullBodyCatchupPermission = bool Function(int preservedLength);',
    'allowFullBodyCatchup',
    "strategy: 'full-body-prefix-catchup-deferred'",
    "session.deferNetwork(reason: 'costly-full-body-catchup')",
    'throw DownloadCatchupDeferred(preservedLength: preservedLength);',
    "'deferredPrefixBytes': preservedLength",
    "'deferredPriority': cancel.priority",
):
    if token not in JOB:
        raise SystemExit(f'dev.199 DownloadJob admission contract missing: {token}')

for token in (
    'void deferNetwork({required String reason})',
    '_requireState(<DownloadState>{DownloadState.queued});',
    "'deferred': true",
):
    if token not in SESSION:
        raise SystemExit(f'dev.199 DownloadSession defer contract missing: {token}')

for token in (
    'final Map<DownloadId, int> _downloadDeferredAtLength = <DownloadId, int>{};',
    '_downloadDeferredAtLength[id] == session.committedLength',
    'on DownloadCatchupDeferred',
    'priority: token.priority',
    'preservedLength: session.committedLength',
):
    if token not in OWNER:
        raise SystemExit(f'dev.199 physical admission owner missing: {token}')

if build >= 241:
    for token in (
        'this.largePrefixBytes = 1024 * 1024',
        'this.largePrefixCatchupRank = 820',
        'bool allowsFullBodyCatchup',
        'demandRank(',
        'fullBodyCatchupCostRank(preservedLength)',
    ):
        if token not in RANK_POLICY:
            raise SystemExit(f'dev.241 rank policy no longer preserves dev.199 cost contract: {token}')
    for token in (
        'rankPolicy.allowsFullBodyCatchup(',
        'priority: priority',
        'preservedLength: preservedLength',
    ):
        if token not in OWNER:
            raise SystemExit(f'dev.241 owner no longer delegates dev.199 admission contract: {token}')
else:
    for token in (
        'const largePrefixBytes = 1024 * 1024;',
        'const foregroundAdjacentPriorityFloor = 820;',
    ):
        if token not in OWNER:
            raise SystemExit(f'dev.199 physical admission owner missing: {token}')

# A low-priority role change must not re-open a deferred full-body catchup;
# promotion to next/visible/current must make it schedulable again.
for token in (
    'large background full-body catchup defers after range is ignored',
    'throwsA(isA<DownloadCatchupDeferred>())',
    'expect(ignoredRange.discardCount, 1)',
    'large unsupported-range catchup waits for foreground-adjacent demand',
    "reason: 'costly-catchup-still-background'",
    'expect(transport.requests, hasLength(1));',
    "reason: 'costly-catchup-foreground-adjacent'",
    'expect(transport.requests, hasLength(2));',
):
    body = JOB_TEST if token in JOB_TEST else LIVE_TEST
    if token not in body:
        raise SystemExit(f'dev.199 catchup regression missing: {token}')

# The policy must use authoritative scheduler priority + committed prefix cost,
# not dev.196/dev.198 observation fields or presentation state.
for forbidden in (
    'duplicatePrefixBytes',
    'sourceHostRemoteIpHash',
    'sourceHostHttpVersion',
    'sourceRhttp',
):
    if forbidden in OWNER:
        raise SystemExit(f'dev.199 physical owner illegally consumes diagnostics: {forbidden}')
for relative in ('apps/app/lib', 'packages/pipeline_runtime/lib'):
    for path in (ROOT / relative).rglob('*.dart'):
        body = path.read_text(encoding='utf-8')
        if 'full-body-prefix-catchup-deferred' in body or 'DownloadCatchupDeferred' in body:
            raise SystemExit(
                f'dev.199 catchup admission leaked into presentation/pipeline: {path.relative_to(ROOT)}'
            )

for body, name in ((ARCH, 'architecture'), (SPEC, 'spec')):
    tokens = ('policy rank', 'full-body', 'defer') if build >= 241 else ('1 MiB', '820', 'full-body', 'defer')
    for token in tokens:
        if token not in body:
            raise SystemExit(f'dev.199 stable contract missing from {name}: {token}')

for body, name in ((STATUS, 'status'), (HANDOFF, 'handoff'), (CHANGELOG, 'changelog')):
    if 'dev.199' not in body:
        raise SystemExit(f'dev.199 missing from {name}')

for path in (
    ROOT / 'docs/adr/0180-cost-aware-full-body-catchup-admission.md',
    ROOT / 'docs/audits/dev199-full-body-catchup-root-cause-audit.md',
    ROOT / 'docs/audits/dev199-validation-results.md',
):
    if not path.exists():
        raise SystemExit(f'dev.199 release document missing: {path.relative_to(ROOT)}')

print('dev.199 cost-aware full-body catchup admission: OK')
