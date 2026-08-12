#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.228 missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.228 forbidden {label}: {token}')

runtime = read('packages/downloads/lib/src/composition_download_transfer_runtime.dart')
owner = read('packages/sessions/lib/src/download_transfer_owner.dart')
cache = read('packages/downloads/lib/src/artifact_cache_manager.dart')
partial = read('packages/downloads/lib/src/partial_download_handoff.dart')
artifact = read('packages/downloads/lib/src/promoted_artifact_cache_handoff.dart')
chapter_test = read('packages/downloads/test/chapter_downloads_test.dart')

for token in (
    'artifactPromotionListener',
    'addPromotionListener(',
    'removePromotionListener(',
    'refreshIndependentExactForPromotedEquivalent',
    "'stage': 'verified-equivalent-promotion-takeover'",
    "'compatibilityPath': true",
    "'compatibilityScope': 'independent-exact-session'",
):
    forbid(runtime + owner + cache, token, 'retired late-promotion takeover surface')

for token in (
    'cache.directEquivalents(exactId)',
    'registry.aliasPhysical(id: exactId, target:',
    "'stage': 'verified-transfer-acquire-alias'",
    "'action': action",
    "'phase': 'acquire-before-physical-session'",
):
    require(runtime, token, 'acquire-time verified physical identity')

require(cache, 'Iterable<DownloadId> directEquivalents(DownloadId id)', 'verified equivalence registry')
require(partial, "'source': 'session-partial-handoff'", 'physical-to-durable partial boundary')
require(artifact, "'source': 'session-artifact-handoff'", 'physical-to-durable artifact boundary')
for token in (
    "event.payload['stage'] == 'verified-transfer-acquire-alias'",
    "event.payload['action'] == 'joined-existing-physical'",
):
    require(chapter_test, token, 'acquire alias behavior regression')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
pub = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
android = re.search(r'^versionCode=(\d+)$', props, re.M)
if pub is None or int(pub.group(1)) < 228:
    raise SystemExit('dev.228 app version mismatch')
if android is None or int(android.group(1)) < 228:
    raise SystemExit('dev.228 Android version mismatch')

for rel in (
    'docs/adr/0208-remove-late-equivalent-promotion-takeover.md',
    'docs/audits/dev228-phase-e-late-takeover-removal-audit.md',
    'docs/audits/dev228-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.228 missing governance: {rel}')

print('dev.228 remove late equivalent takeover: OK')
