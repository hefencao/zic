#!/usr/bin/env python3
"""Guard dev.257 local-completion / provider-admission separation."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.257 contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains rejected dev.257 shape: {present}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 257:
    raise SystemExit('App build must be >=257')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

job = 'packages/sessions/lib/src/download_job.dart'
require(
    job,
    'static Future<bool> completeWithoutTransport(',
    'if (session.state == DownloadState.promoted) return true;',
    'session.totalLength != session.committedLength',
    'await session.promote();',
    'if (await completeWithoutTransport(',
)

owner = 'packages/sessions/lib/src/download_transfer_owner.dart'
require(
    owner,
    'final preparedClaim = _preferredClaim(id);',
    'if (await DownloadJob.completeWithoutTransport(',
    "'stage': 'transfer-admission'",
    "'action': 'local-completion-short-circuit'",
    'final currentClaim = _preferredClaim(id);',
    'final retainedTransport =',
    'provider.retainedTransportFor?.call(sourceId.canonicalUri);',
    'kind: TraceEventKind.downloadStarted,',
)
text = read(owner)
short = text.index("'action': 'local-completion-short-circuit'")
provider = text.index('provider.retainedTransportFor?.call(sourceId.canonicalUri)', short)
started = text.index('kind: TraceEventKind.downloadStarted,', provider)
if not short < provider < started:
    raise SystemExit('local completion must precede provider lookup and downloadStarted')

require(
    'packages/sessions/test/download_transfer_owner_test.dart',
    'prepared local completion bypasses provider transport admission',
    'expect(transportLookups, 0);',
    'expect(transport.opens, 0);',
    "event.payload['action'] == 'local-completion-short-circuit'",
)

for path in (
    'docs/adr/0236-local-completion-before-provider-admission.md',
    'docs/audits/dev257-local-completion-provider-admission-root-cause-audit.md',
    'docs/audits/dev257-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.257 governance file: {path}')

require('docs/ARCHITECTURE.md', '本地artifact/partial authority', '`downloadStarted`只描述真实provider transport attempt')
require('docs/SPEC.md', 'MUST NOT把local completion记为network start', '`downloadStarted` MUST只在仍需要真实provider transport attempt时记录')
require('tool/check.sh', 'test_dev257_local_completion_provider_admission.py')

# This round is intentionally admission-order only.
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'reservedHighPrioritySlots: 1',
)
require(
    'packages/pipeline/lib/src/animated_prefetch_policy.dart',
    'if (offset == 1) return 5;',
    'if (offset == 2) return 3;',
    'if (offset == -1) return 2;',
)
print('dev.257 local completion/provider admission closure: OK')
