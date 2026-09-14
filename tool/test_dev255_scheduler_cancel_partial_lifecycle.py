#!/usr/bin/env python3
"""Guard dev.255 scheduler-cancellation / partial-lifecycle separation."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.255 contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains superseded dev.255 shape: {present}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 255:
    raise SystemExit('App build must be >=255')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

require(
    'packages/sessions/lib/src/download_session.dart',
    'if (error is Failure && error.code == ErrorCode.cancelled)',
    'await pause(lease);',
    '_state = DownloadState.failed;',
)
require(
    'packages/sessions/lib/src/download_job.dart',
    'Future<void> _finishWriterAfterAttemptError(',
    '(error is Failure && error.code == ErrorCode.cancelled)',
    'await session.pause(writer);',
    'await session.fail(writer, error);',
)
job = read('packages/sessions/lib/src/download_job.dart')
if job.count('await _finishWriterAfterAttemptError(') < 3:
    raise SystemExit('DownloadJob must route all three attempt-error closures through the typed cancellation helper')

require(
    'packages/sessions/lib/src/download_transfer_owner.dart',
    "'partialPreserved': session.committedLength > 0",
    "'partialState': session.state.name",
)
require(
    'packages/sessions/test/download_job_test.dart',
    'cancelled transport attempt preserves an idle resumable partial',
)
require(
    'packages/sessions/test/download_session_test.dart',
    'cancelled writer attempt preserves partial without failed state',
)
require(
    'packages/sessions/test/download_transfer_owner_test.dart',
    'scheduler preemption preserves committed partial as idle state',
)

for path in (
    'docs/adr/0234-scheduler-cancellation-partial-lifecycle-separation.md',
    'docs/audits/dev255-preemption-partial-failure-root-cause-audit.md',
    'docs/audits/dev255-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.255 governance file: {path}')

require('docs/ARCHITECTURE.md', 'scheduler/consumer typed `ErrorCode.cancelled`', '`DownloadState.failed`只允许表达真实')
require('docs/SPEC.md', 'MUST NOT写成`DownloadState.failed / Failure(cancelled)`')
require('tool/check.sh', 'test_dev255_scheduler_cancel_partial_lifecycle.py')

# This round must not change the scheduling/window constants to hide the lifecycle bug.
require(
    'packages/pipeline/lib/src/role_window.dart',
    'if (observation.interaction == Interaction.scrubbing)',
    'return RoleWindow(roles);',
)
require(
    'packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
    'networkConcurrency: 5',
)
require(
    'packages/downloads/lib/src/download_resource_coordinator.dart',
    'maxActive: 5',
    'reservedHighPrioritySlots: 1',
)
reject(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'maxActive: ReaderPipelineProfile.stable.networkConcurrency',
)
print('dev.255 scheduler cancellation / partial lifecycle: OK')
