#!/usr/bin/env python3
"""Guard dev.274 compile closure and local->network priority continuity."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def text(path: str) -> str:
    return (ROOT / path).read_text()

def req(ok: bool, msg: str) -> None:
    if not ok:
        raise SystemExit(msg)

def require(path: str, *needles: str) -> None:
    body = text(path)
    missing = [needle for needle in needles if needle not in body]
    req(not missing, f'{path} missing dev.274 contract: {missing}')

pub = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 274, 'dev.274 app version missing')
props = text('apps/app/android/zic-version.properties')
vm = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(vm is not None and int(vm.group(1)) >= 274, 'dev.274 Android version floor missing')

transport = text('packages/transport/lib/src/transport.dart')
require('packages/transport/lib/src/transport.dart',
        'bool get isEmpty => etag == null && lastModified == null;',
        'bool get canResume => !isEmpty;')
chapter = (
    text('packages/downloads/lib/src/chapter_downloads.dart')
    + text('packages/downloads/lib/src/persistent_download_partial_resume.dart')
)
req('validators.isNotEmpty' not in chapter,
    'Validators has no isNotEmpty getter; compile-breaking call remains')
require('packages/downloads/lib/src/persistent_download_partial_resume.dart',
        'validators.canResume && validatorRequestUri != id.canonicalUri')

owner = text('packages/sessions/lib/src/download_transfer_owner.dart')
for marker in (
    '_preparedNetworkAdmissions',
    '_drainPreparedNetworkAdmissions()',
    "'stage': 'post-local-network-admission'",
    "'action': 'deferred-by-higher-local-priority'",
    'blockingPriority > priority',
):
    req(marker in owner, f'local->network priority seam missing: {marker}')
start = owner.index('void _startLocalPreparation(')
end = owner.index('Future<void> _runLocalPreparation(', start)
seam = owner[start:end]
req('_preparedNetworkAdmissions[id] = session;' in seam,
    'completed local preparation must enter owner admission arbiter')
req('_drainPreparedNetworkAdmissions();' in seam,
    'normal local completion must drain through the owner admission arbiter')
req('control.cancelled &&' in seam and
    'session.committedLength == 0' in seam and
    '_ensureDownloadTask(id, session);' in seam,
    'only a zero-byte priority-preempted local prepare may re-enter normal preparation')

require('packages/sessions/test/download_transfer_owner_test.dart',
        'post-local network admission preserves higher demand priority',
        'expect(openOrder, isEmpty);',
        'expect(openOrder.first, high.canonicalUri);')

for path in (
    'docs/adr/0252-local-prepare-network-priority-continuity.md',
    'docs/audits/dev274-compile-and-local-admission-priority-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.274 governance file: {path}')
require('docs/NEXT_CHAT_HANDOFF.md', 'post-local network-admission rank barrier', '0-byte victim 自动重排 local prepare')
require('CHANGELOG.md', '0.31.0-dev.274', 'Validators.canResume')

# Frozen concurrency/runtime safety boundaries remain unchanged.
require('docs/NEXT_CHAT_HANDOFF.md',
        '7/3', '2/1', '5个transport lease', 'current handoff')
require('packages/plugin_host/lib/src/runtime_executors.dart',
        'maxConcurrentInvocations: 1')

print('PASS: dev.274 compile closure and local->network priority continuity')
