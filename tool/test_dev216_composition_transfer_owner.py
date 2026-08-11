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


owner = read('packages/sessions/lib/src/download_transfer_owner.dart')
exports = read('packages/sessions/lib/sessions.dart')
live = read('packages/sessions/lib/src/live_coordinator.dart')
pipe = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
test = read('packages/sessions/test/download_transfer_owner_test.dart')

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
    "reason: 'remaining-consumer'",
    'await net.idleKeys(providerKeys);',
    'Future<void> _persistUnclaimed(DownloadSession session) async',
    'final flush = callback(session);',
    'await flush;',
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
    '_downloadTransfer.reconcile(sessionId, _revision, diff);',
    'await _downloadTransfer.dispose();',
    '_downloadTransfer.refreshScheduling();',
):
    require(live, token, 'LiveCoordinator consumer delegation')

for token in (
    'final class _TransferRuntimeKey',
    'identical(artifactCacheManager, other.artifactCacheManager)',
    'identical(partialDownloadStore, other.partialDownloadStore)',
    'identical(net, other.net)',
    'final class _PipelineDownloadTransferRuntimePool',
    'final class _PipelineDownloadTransferRuntime',
    'owner = DownloadTransferOwner(',
    'persistUnclaimed: partialDownloadHandoff == null',
    '_downloads = _transferRuntime.registry;',
    '_downloadTransfer = _transferRuntime.attachReader(',
    'await _transferRuntimePool.disposeIdle();',
    "throw StateError('cannot dispose physical transfers with active consumers')",
):
    require(pipe, token, 'composition runtime ownership')
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
    'final consumer detach persists committed physical partial after writer exits',
    'expect(registry.sessions, hasLength(1));',
    'expect(owner.claimCount(id), 2);',
    'expect(persistCalls, 1);',
):
    require(test, token, 'dev.216 behavioral ownership regression')

for token in ('GlobalDownloadRegistry', 'CompositionDownloadRegistry', 'static final DownloadRegistry'):
    forbid(pipe + owner, token, 'parallel ad-hoc physical registry')

for rel in (
    'docs/adr/0197-composition-physical-transfer-owner-for-exact-download-id.md',
    'docs/audits/dev216-composition-transfer-owner-root-cause-audit.md',
    'docs/audits/dev216-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.216 governance file missing: {rel}')

import re
pubspec = read('apps/app/pubspec.yaml')
version_props = read('apps/app/android/zic-version.properties')
version_match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.MULTILINE)
android_match = re.search(r'^versionCode=(\d+)$', version_props, re.MULTILINE)
if version_match is None or int(version_match.group(1)) < 216:
    raise SystemExit('dev.216 app version regression')
if android_match is None or int(android_match.group(1)) < 216:
    raise SystemExit('dev.216 Android version regression')
print('dev.216 composition physical transfer owner: OK')
