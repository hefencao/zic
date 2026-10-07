#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
read = lambda p: (ROOT / p).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.234 missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.234 forbidden {label}: {token}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
build_match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
android_match = re.search(r'^versionCode=(\d+)$', props, re.M)
if build_match is None or int(build_match.group(1)) < 234:
    raise SystemExit('dev.234 app version missing')
if android_match is None or int(android_match.group(1)) != int(build_match.group(1)):
    raise SystemExit('dev.234 Android version mismatch')

registry = read('packages/sessions/lib/src/download_registry.dart')
owner = read('packages/sessions/lib/src/download_transfer_owner.dart')
runtime = read('packages/downloads/lib/src/composition_download_transfer_runtime.dart')
retention = read('packages/downloads/lib/src/physical_transfer_retention.dart')
partial = read('packages/downloads/lib/src/partial_download_handoff.dart')
promoted = read('packages/downloads/lib/src/promoted_artifact_cache_handoff.dart')
test = read('packages/downloads/test/physical_transfer_retention_test.dart')

for token in (
    'DownloadSession? takeIdlePhysical(DownloadId id)',
    '_sessions.remove(physicalId);',
    '_physicalAliases.remove(alias);',
):
    require(registry, token, 'mechanical registry retirement')
for token in ('PartialDownloadHandoff', 'PartialDownloadStore', 'ArtifactCacheManager', 'maxIdlePartial'):
    forbid(registry, token, 'sessions registry durable/retention policy')

for token in (
    'Future<bool> retireIdlePhysical(',
    'bool discardOwnedArtifactBody = false,',
    'final retired = registry.takeIdlePhysical(physicalId);',
    'await session.dispose(',
    'discardOwnedArtifactBody: discardOwnedArtifactBody',
):
    require(owner, token, 'scheduler-owned physical retirement')
for token in ('PartialDownloadHandoff', 'PartialDownloadStore', 'ArtifactCacheManager', 'hot-retention-pressure'):
    forbid(owner, token, 'sessions owner durable/retention policy')

for token in (
    'final class PhysicalTransferRetention',
    'this.maxIdlePartialSessions = 32',
    'this.maxIdlePartialBytes = 256 * 1024 * 1024',
    'handoff == null || !await handoff.settleAutomatic(session)',
    "reason: 'hot-retention-pressure'",
    "source': 'composition-physical-retention'",
    "action: bytes > 0 ? 'retired-partial' : 'retired-empty'",
):
    require(retention, token, 'composition bounded retention')
for token in ('Reader', 'PipelineController', 'DecodeSession', 'holder'):
    # The class documentation may say Reader/Pipeline are not owners; reject only imports/capabilities.
    if token.startswith('package:'):
        forbid(retention, token, 'reader/pipeline retention coupling')
forbid(retention, "package:pipeline/", 'pipeline retention dependency')
forbid(retention, "package:reader/", 'reader retention dependency')

for token in (
    'maxIdlePartialSessions = 32',
    'maxIdlePartialBytes = 256 * 1024 * 1024',
    'PhysicalTransferRetention(',
    '_physicalTransferRetention?.observe(session);',
    'Future<void> settlePhysicalRetention()',
    'await _physicalTransferRetention?.dispose();',
    'await partialDownloadHandoff?.drain(registry.sessions);',
):
    require(runtime, token, 'composition retention ownership')
forbid(runtime, 'persistUnclaimed:', 'claim-detach persistence injection')

for token in (
    'final Map<DownloadSession, Future<bool>> _stores',
    'Future<bool> persist(',
    "reason: 'runtime-dispose'",
    "'reason': reason",
):
    require(partial, token, 'partial durable owner handoff')
require(promoted, 'Future<bool> settleAutomatic(DownloadSession session)', 'ordinary promoted settle barrier')

for token in (
    'promoted idle physical session stays hot inside bounded retention',
    'promoted pressure retires only the oldest durable hot session',
    'promoted hot body remains when immutable handoff is unavailable',
    'idle partial retention keeps recent hot prefixes and cold-stores victim',
    'promoted retirement preserves equivalence-only durable ownership',
    'failed cold-partial handoff keeps the hot physical owner',
    'retiring physical owner removes acquire-time aliases to that session',
):
    require(test, token, 'bounded retention behavior regression')

# Retention policy must not leak upward into Reader/Pipeline production code.
for rel in (
    'packages/pipeline/lib',
    'packages/pipeline_runtime/lib',
    'packages/reader/lib',
    'packages/reader_runtime/lib',
    'apps/app/lib',
):
    base = ROOT / rel
    if not base.exists():
        continue
    for path in base.rglob('*.dart'):
        text = path.read_text(encoding='utf-8')
        if 'maxIdlePartialSessions' in text or 'maxIdlePartialBytes' in text or 'PhysicalTransferRetention' in text:
            raise SystemExit(f'dev.234 retention budget leaked upward: {path.relative_to(ROOT)}')

for rel in (
    'docs/archive/adr/0214-bounded-physical-transfer-retention.md',
    'docs/archive/audits/dev234-physical-retention-root-cause-audit.md',
    'docs/archive/audits/dev234-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.234 governance file missing: {rel}')

print('dev.234 bounded physical transfer retention: OK')
