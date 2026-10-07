#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(cond: bool, message: str) -> None:
    if not cond:
        raise SystemExit(f'FAIL: {message}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
session = read('packages/sessions/lib/src/download_session.dart')
job = read('packages/sessions/lib/src/download_job.dart')
owner = read('packages/sessions/lib/src/download_transfer_owner.dart')
progress = read('packages/pipeline_runtime/lib/src/pipeline_transfer_progress.dart')
reader = read('packages/reader_runtime/lib/src/reader_transfer_progress_indicator.dart')
owner_test = read('packages/sessions/test/download_transfer_owner_test.dart')
progress_test = read('packages/pipeline_runtime/test/pipeline_transfer_progress_test.dart')
arch = read('docs/ARCHITECTURE.md')
spec = read('docs/SPEC.md')
check = read('tool/check.sh')

m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
require(m is not None and int(m.group(1)) >= 244, 'App build must be >=244')
m2 = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
require(m2 is not None and m2.group(1) == m.group(1), 'Android versionCode must match App build')

require('_handoffActiveProviderIfNeeded' not in owner, 'logical exact/rank changes must not replace an admitted equivalent provider')
require("'active-provider-handoff'" not in owner, 'provider rank takeover trace/control flow must be removed')
require('current exact demand migrates physical rank without replacing the admitted equivalent provider' in owner_test,
        'current exact switch must retain admitted provider while migrating physical rank')
require('provider exact selection is task lifetime state rather than scheduler policy' in owner_test,
        'provider exact authority must be tested as task-lifetime state')
require('expect(currentTransport.opened.isCompleted, isFalse);' in owner_test,
        'equivalent current must not open a competing provider request')

for token in (
    'networkAttemptSequence',
    'networkAttemptActive',
    'networkCursorLength',
    'beginNetworkAttemptProgress',
    'advanceNetworkAttemptProgress',
    'endNetworkAttemptProgress',
):
    require(token in session, f'DownloadSession missing transient transport progress: {token}')
require('session.beginNetworkAttemptProgress(' in job and 'response.rangeStart' in job,
        'DownloadJob must start transport cursor from the actual response range')
require('session.advanceNetworkAttemptProgress(' in job and 'networkCursor' in job,
        'DownloadJob must advance the one physical transport cursor')
require('session.endNetworkAttemptProgress(' in job,
        'transport cursor attempt lifetime must close with DownloadJob run')
require('networkCursor = value;' in job and 'full-body-prefix-catchup' in job,
        'full-body prefix replay must expose current transport position without changing partial authority')

require('final int partialBytes;' in progress and 'final int transportBytes;' in progress,
        'Pipeline progress must separate authoritative partial and transient transport bytes')
require('PipelineTransferPhase.replayingPrefix' in progress,
        'Pipeline progress must expose prefix replay instead of looking stalled')
require('speedBytesPerSecond' in progress and '* 0.7 + instant * 0.3' in progress,
        'current transport speed must use the Vibe-style smoothed sample')
require('partialBytes: snapshot.committedLength' in progress and
        'transportBytes: snapshot.networkCursorLength' in progress,
        'progress must project both facts from the same resolved physical DownloadSession')

require('class _TransferWavePainter extends CustomPainter' in reader,
        'current transport progress must use a wave painter')
require('theme.colorScheme.secondary' in reader,
        'authoritative max partial must remain a distinct straight secondary line')
require('const base = 128 * 1024.0;' in reader and
        'const max = 8 * 1024 * 1024.0;' in reader and
        'Color.lerp(Colors.red, Colors.amber' in reader and
        'Color.lerp(Colors.amber, Colors.green' in reader,
        'wave color must follow the inspected VibeVenera logarithmic speed ramp')
require('已有页面partial，正在重读页面前缀' in reader,
        'single-lane UI semantics must still identify transport prefix replay')
require('replayingPrefix' in progress_test and 'transportBytes' in progress_test,
        'pipeline behavior regression must distinguish replay cursor from partial')

require('provider exact' in arch and 'task lifetime' in arch,
        'Architecture must separate admitted provider lifetime from scheduler rank')
require('transport cursor' in arch and 'partial' in arch,
        'Architecture must name transient transport cursor versus partial authority')
require('provider exact' in spec and 'admitted' in spec,
        'SPEC must freeze provider-task stability after physical equivalence')
require('transport cursor' in spec,
        'SPEC must freeze the dual progress authority boundary')
require('test_dev244_transport_cursor_provider_stability.py' in check,
        'dev.244 gate must be wired into tool/check.sh')

for path in (
    'docs/archive/adr/0224-admitted-provider-stability-and-transport-cursor.md',
    'docs/archive/audits/dev244-redundant-prefix-progress-root-cause-audit.md',
):
    require((ROOT / path).is_file(), f'missing governance file: {path}')

print('PASS: dev.244 transport cursor + admitted provider stability')
