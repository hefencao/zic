#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
read = lambda p: (ROOT / p).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.233 missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.233 forbidden {label}: {token}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
build_match = re.search(r'^version: \d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)$', pubspec, re.M)
android_match = re.search(r'^versionCode=(\d+)$', props, re.M)
if build_match is None or int(build_match.group(1)) < 233:
    raise SystemExit('dev.233 app version missing')
if android_match is None or int(android_match.group(1)) != int(build_match.group(1)):
    raise SystemExit('dev.233 Android version mismatch')

owner = read('packages/sessions/lib/src/download_transfer_owner.dart')
runtime = read('packages/downloads/lib/src/composition_download_transfer_runtime.dart')
handoff = read('packages/downloads/lib/src/promoted_artifact_cache_handoff.dart')
owner_test = read('packages/sessions/test/download_transfer_owner_test.dart')
chapter_test = read('packages/downloads/test/chapter_downloads_test.dart')
handoff_test = read('packages/downloads/test/promoted_artifact_cache_handoff_test.dart')

for token in ('persistUnclaimed', '_persistUnclaimed', '_unclaimedFlushes'):
    forbid(owner, token, 'sessions-owned durable partial lifecycle')
for token in (
    'prepareDownload: partialDownloadHandoff == null',
    '_restoreLocalSingleFlight(',
    'tracked = handoff.restoreInto(session, control: control)',
    'await owner.dispose();',
    'await partialDownloadHandoff?.drain(registry.sessions);',
):
    require(runtime, token, 'composition retirement partial boundary')
forbid(runtime, 'persistUnclaimed:', 'durable partial callback injection')
require(owner_test, 'final consumer detach retains hot physical partial for later reuse', 'hot partial retention regression')

for token in (
    'final candidates = <DownloadId, DownloadSession>{};',
    '..sort(_compareEquivalentPhysicalCandidates);',
    'int _physicalReuseAuthority(DownloadSession session)',
    "'candidateOwners': candidateOwners",
    "'preferred-existing-owner'",
):
    require(runtime, token, 'preferred existing physical owner reuse')
forbid(runtime, 'rejected-ambiguous-existing-owners', 'new third physical owner fallback')
for token in (
    'fresh verified identity reuses preferred existing physical owner',
    "expect(alias.payload['candidateOwners'], 2);",
    "expect(alias.payload['physicalState'], DownloadState.promoted.name);",
):
    require(chapter_test, token, 'multi-owner reuse behavior')

for token in (
    '_completedAutomaticCommits =',
    '_completedAutomaticCommits[id] == session.epoch',
    '_completedAutomaticCommits[id] = epoch;',
):
    require(handoff, token, 'immutable automatic handoff dedupe')
require(handoff_test, 'hasLength(1)', 'single automatic backend probe regression')

for rel in (
    'docs/archive/adr/0213-physical-reuse-and-handoff-lifecycle-consolidation.md',
    'docs/archive/audits/dev233-reuse-handoff-consolidation-audit.md',
    'docs/archive/audits/dev233-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.233 governance file missing: {rel}')

print('dev.233 reuse + handoff consolidation: OK')
