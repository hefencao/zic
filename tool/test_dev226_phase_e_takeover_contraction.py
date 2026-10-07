#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.226 missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.226 forbidden {label}: {token}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
pub = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
android = re.search(r'^versionCode=(\d+)$', props, re.M)
if pub is None or int(pub.group(1)) < 226:
    raise SystemExit('dev.226 app version mismatch')
if android is None or int(android.group(1)) < 226:
    raise SystemExit('dev.226 Android version mismatch')
build = int(pub.group(1))

runtime = read('packages/downloads/lib/src/composition_download_transfer_runtime.dart')
owner = read('packages/sessions/lib/src/download_transfer_owner.dart')
coordinator = read('packages/sessions/lib/src/live_coordinator.dart')
chapter_test = read('packages/downloads/test/chapter_downloads_test.dart')
partial = read('packages/downloads/lib/src/partial_download_handoff.dart')
artifact = read('packages/downloads/lib/src/promoted_artifact_cache_handoff.dart')

for token in (
    "'stage': 'verified-transfer-acquire-alias'",
    "'action': action",
    "'physicalToken': workspace.layout.tokenFor(candidate)",
    "'phase': 'acquire-before-physical-session'",
):
    require(runtime, token, 'composition acquire alias observability')

if build >= 228:
    for token in (
        'artifactPromotionListener',
        'cache.addPromotionListener(listener);',
        'owner.refreshIndependentExactForPromotedEquivalent(equivalent);',
    ):
        forbid(runtime, token, 'retired composition late takeover')
    for token in (
        'void refreshIndependentExactForPromotedEquivalent(',
        "'compatibilityPath': true",
        "'compatibilityScope': 'independent-exact-session'",
    ):
        forbid(owner, token, 'retired independent exact late compatibility path')
else:
    for token in (
        'final independent = registry.findExact(equivalent);',
        'registry.resolvePhysicalId(equivalent) != equivalent',
        'owner.refreshIndependentExactForPromotedEquivalent(equivalent);',
    ):
        require(runtime, token, 'composition acquire/legacy separation')
    for token in (
        'void refreshIndependentExactForPromotedEquivalent(',
        'registry.resolvePhysicalId(id) != id',
        'final session = registry.findExact(id);',
        "'compatibilityPath': true",
        "'compatibilityScope': 'independent-exact-session'",
    ):
        require(owner, token, 'independent exact late compatibility path')

forbid(coordinator, 'refreshDownloadForLocalArtifact', 'Reader-owned late takeover delegation')
forbid(owner, 'void refreshForLocalArtifact(DownloadId id) =>', 'consumer-owned late takeover delegation')

for token in (
    "event.payload['stage'] == 'verified-transfer-acquire-alias'",
    "event.payload['action'] == 'joined-existing-physical'",
    "'verified-equivalent-promotion-takeover'",
    'isEmpty,',
):
    require(chapter_test, token, 'acquire alias observability behavior regression')

require(partial, "'source': 'session-partial-handoff'", 'cold partial persistence boundary')
require(artifact, "'source': 'session-artifact-handoff'", 'immutable artifact persistence boundary')

for rel in (
    'docs/archive/adr/0206-phase-e-late-takeover-contraction-and-alias-observability.md',
    'docs/archive/audits/dev226-phase-e-compensation-evidence-audit.md',
    'docs/archive/audits/dev226-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.226 missing governance: {rel}')

print('dev.226 phase-e takeover contraction: OK')
