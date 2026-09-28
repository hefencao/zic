#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')


def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'forbidden {label}: {token}')


import re
pubspec = read('apps/app/pubspec.yaml')
version_props = read('apps/app/android/zic-version.properties')
version_match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.MULTILINE)
android_match = re.search(r'^versionCode=(\d+)$', version_props, re.MULTILINE)
if version_match is None or android_match is None:
    raise SystemExit('dev.216 app version missing')
build = int(version_match.group(1))

owner = read('packages/sessions/lib/src/download_transfer_owner.dart')
exports = read('packages/sessions/lib/sessions.dart')
live = read('packages/sessions/lib/src/live_coordinator.dart')
pipe = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
runtime = read('packages/downloads/lib/src/composition_download_transfer_runtime.dart')
test = read('packages/sessions/test/download_transfer_owner_test.dart')
retention_test = read('packages/downloads/test/physical_transfer_retention_test.dart')

require(exports, "export 'src/download_transfer_owner.dart';", 'composition transfer owner export')
for token in (
    'final class DownloadTransferOwner',
    'final DownloadRegistry registry;',
    'final Map<DownloadId, String> _networkTaskKeys',
    'final Map<DownloadId, int> _downloadRetryRounds',
    'final Set<DownloadId> _downloadTerminalFailures',
    'final Map<DownloadId, int> _downloadDeferredAtLength',
    "final taskKey = 'transfer:${++_taskSequence}:${id.key}';",
    'attachLegacyDemand: false',
    '_refreshClaimScheduling(id, session);',
    'await net.idleKeys(providerKeys);',
):
    require(owner, token, 'single physical transfer owner')

for token in (
    'Map<DownloadId, String> _networkTaskKeys',
    'Map<DownloadId, int> _downloadRetryRounds',
    'Set<DownloadId> _downloadTerminalFailures',
    'Future<void> _runDownload(',
):
    forbid(live, token, 'Reader-local duplicate physical owner')
for token in (
    'DownloadTransferConsumer? downloadTransfer',
    '_downloadTransfer.replaceDemands(',
    'await _downloadTransfer.dispose();',
    '_downloadTransfer.refreshScheduling();',
):
    require(live, token, 'LiveCoordinator consumer delegation')

for token in (
    'final class CompositionDownloadTransferRuntimePool',
    'identical(artifactCacheManager, other.artifactCacheManager)',
    'identical(partialDownloadStore, other.partialDownloadStore)',
    'identical(net, other.net)',
    'final class CompositionDownloadTransferRuntime',
    'owner = DownloadTransferOwner(',
):
    require(runtime, token, 'composition runtime ownership')
for token in (
    'if (exact?.demanded == true) return exactId;',
    "'preferred-equivalent-over-idle-exact'",
    'candidates[exactId] = exact;',
):
    require(runtime, token, 'verified idle exact carrier re-selection')
for token in (
    'idle exact partial yields to a more advanced verified carrier',
    'demanded exact session does not switch to an equivalent carrier',
):
    require(retention_test, token, 'dev.216 version physical carrier regression')
for token in (
    '_downloads = _transferRuntime.registry;',
    '_downloadTransfer = _transferRuntime.attachConsumer(',
    'await _transferRuntimePool.disposeIdle();',
    "throw StateError('cannot dispose physical transfers with active consumers')",
):
    require(pipe, token, 'Reader attachment to composition runtime')
forbid(pipe, '_PipelineDownloadTransferRuntime', 'obsolete Reader-private composition runtime')
if pipe.count('transferRuntimePool: _transferRuntimePool,') < 5:
    raise SystemExit('factory clones do not consistently share transfer-runtime pool')

reader_start = pipe.index('final class PipelineReaderSession {')
reader = pipe[reader_start:]
for token in (
    '_ingresses = DownloadIngressProjectionRegistry(',
    'late final DownloadIngressProjectionRegistry _ingresses;',
    'late final DecodeRegistry _decodes;',
):
    require(reader, token, 'Reader-local decode/ingress ownership')
for token in ('_downloads.dispose()', '_workspace.dispose()'):
    forbid(reader, token, 'Reader destroying composition physical owner')

for token in (
    'two consumers join one exact physical transfer and writer',
    'disposing active provider preserves remaining consumer and reopens once',
    'removing final executable claim revokes local preparation with retained consumer',
    'expect(registry.sessions, hasLength(1));',
    'expect(owner.claimCount(id), 2);',
):
    require(test, token, 'dev.216 behavioral ownership regression')
if build >= 233:
    require(
        test,
        'final consumer detach retains hot physical partial for later reuse',
        'dev.233 hot partial retention regression',
    )
    for token in ('persistUnclaimed', '_unclaimedFlushes', '_persistUnclaimed'):
        forbid(owner, token, 'sessions durable partial policy after dev.233')
    require(runtime, 'await partialDownloadHandoff?.drain(registry.sessions);', 'true runtime retirement partial handoff')
    forbid(runtime, 'persistUnclaimed:', 'per-unclaimed persistence injection after dev.233')
else:
    for token in (
        'final consumer detach persists committed physical partial after writer exits',
        'expect(persistCalls, 1);',
    ):
        require(test, token, 'dev.216 durable partial ownership regression')

for token in ('GlobalDownloadRegistry', 'CompositionDownloadRegistry', 'static final DownloadRegistry'):
    forbid(pipe + owner, token, 'parallel ad-hoc physical registry')

for rel in (
    'docs/adr/0197-composition-physical-transfer-owner-for-exact-download-id.md',
    'docs/audits/dev216-composition-transfer-owner-root-cause-audit.md',
    'docs/audits/dev216-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.216 governance file missing: {rel}')

if build < 216:
    raise SystemExit('dev.216 app version regression')
if android_match is None or int(android_match.group(1)) < 216:
    raise SystemExit('dev.216 Android version regression')
print('dev.216 composition physical transfer owner: OK')
