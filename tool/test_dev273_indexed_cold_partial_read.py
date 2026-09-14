#!/usr/bin/env python3
"""Guard dev.273 indexed durable-partial read ownership."""
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
    missing = [n for n in needles if n not in body]
    req(not missing, f'{path} missing dev.273 contract: {missing}')

pub = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 273, 'dev.273 app version missing')
props = text('apps/app/android/zic-version.properties')
vm = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(vm is not None and int(vm.group(1)) >= 273, 'dev.273 Android version missing')

chapter_path = 'packages/downloads/lib/src/chapter_downloads.dart'
persistent_store_path = 'packages/downloads/lib/src/persistent_download_artifact_store.dart'
partial_resume_path = 'packages/downloads/lib/src/persistent_download_partial_resume.dart'
chapter = text(chapter_path)
persistent_store = text(persistent_store_path)
partial_resume = text(partial_resume_path)
download_storage = chapter + persistent_store + partial_resume
start = persistent_store.index('Future<PartialDownloadEntry?> _openPartialDownload(DownloadId id) async')
end = persistent_store.index('\n  @override\n  Future<void> storePartialDownload', start)
method = persistent_store[start:end]
for marker in (
    '_index.get(id.key)',
    'record.state != CacheState.partial',
    '_readIndexedPartialResumeState(record.path, id)',
    '_readIndexedChunks(',
    '_index.touch(id.key, touchedUs)',
):
    req(marker in method, f'indexed cold-partial read marker missing: {marker}')
for forbidden in ('_registry.get(id)', 'session.restore(', 'storePartialDownload('):
    req(forbidden not in method, f'read lookup must not materialize/mutate session: {forbidden}')
for marker in (
    'final class _IndexedPartialResumeState',
    'explicitDifferentOwner',
    "File('$partialPath.meta')",
    'validatorRequestUri != id.canonicalUri',
):
    req(marker in download_storage, f'indexed cold-partial support marker missing: {marker}')

require(
    'packages/downloads/test/chapter_downloads_test.dart',
    'cold partial misses do not materialize durable DownloadSessions',
    'expect(service.materializedSessionCount, 0);',
    'expect(reopened.materializedSessionCount, 0);',
)
require(
    'packages/sessions/lib/src/download_transfer_owner.dart',
    "'local-hydration-miss'",
    "'local-hydration-ready'",
    "'stage': 'physical-local-prepare'",
)

# dev.272 remains the owner of pre-admission preparation and local read scheduling.
owner = text('packages/sessions/lib/src/download_transfer_owner.dart')
prepare = owner.index('final prepare = prepareDownload;')
task_key = owner.index("final taskKey = 'transfer:", prepare)
req(prepare < task_key, 'local preparation must stay before NetLane task creation')
require(
    'packages/downloads/lib/src/partial_download_handoff.dart',
    'ArtifactCacheReadScheduler?',
    'scheduler.acquire(',
    'priority: priority,',
    'priority: () => session.effectivePriority',
)

for path in (
    'docs/adr/0251-indexed-durable-partial-read-authority.md',
    'docs/audits/dev273-durable-partial-read-owner-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.273 governance file: {path}')
require('docs/ARCHITECTURE.md', 'persistent index/file直接裁决', '不得为读取或存在性探测materialize durable-store `DownloadSession`')
require('docs/SPEC.md', 'durable partial existence/read MUST由persistent index/file authority直接解析')
require('docs/IMPLEMENTATION_STATUS.md', 'cold partial', 'materialize durable-store')
require('docs/NEXT_CHAT_HANDOFF.md', 'cold partial', 'verified-equivalent READY')
require('CHANGELOG.md', '0.31.0-dev.273', 'durable partial read owner')

# Frozen policy/resource boundaries remain unchanged.
require('docs/NEXT_CHAT_HANDOFF.md', '7/3', '2/1', '5个transport lease', 'current handoff')

print('PASS: dev.273 indexed cold-partial read authority')
