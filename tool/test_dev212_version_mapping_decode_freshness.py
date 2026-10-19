#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')


def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'superseded {label}: {token}')


catalog = read('packages/catalog/lib/src/source_catalog.dart')
for token in (
    "final verifiedAtValue = json['verifiedAt'];",
    'DateTime.tryParse(verifiedAtValue)',
    'verifiedAt: verifiedAt,',
):
    require(catalog, token, 'typed mapping verifiedAt decode')
forbid(catalog, 'DateTime.parse(verifiedAt)', 'Object-typed verifiedAt parse')

version_lifecycle = read('apps/app/lib/home_version_reuse_lifecycle.dart')
for token in (
    'final proofAlreadyUsable = upgradeLegacyIntervalProof',
    'focusedRevision == focus.chapter.sourceRevision',
    'focusedPageCount == focus.chapter.pages.length',
    'VerifiedArtifactReusePlan.needsIntervalProbe(mapping)',
    'currentMapping.predecessorSourceRevision ==',
    'currentMapping.successorSourceRevision ==',
    'intervalProbeVersion: VerifiedArtifactReusePlan.intervalProbeVersion',
):
    require(version_lifecycle, token, 'version mapping freshness ownership')
for stale in (
    '_versionPageMappingRevalidationInterval',
    '_versionPageMappingsAreFresh',
):
    forbid(version_lifecycle, stale, 'TTL-based version mapping freshness')

version = re.search(r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 212:
    raise SystemExit('App build must be at least 212')
if int(version.group(1)) >= 229:
    forbid(version_lifecycle, '_reuseSourceVersionDurablePartials', 'eager cold partial copy during mapping warmup')
    handoff = read('packages/downloads/lib/src/partial_download_handoff.dart')
    require(handoff, 'equivalentCandidates', 'cold partial reuse at physical prepare boundary')
else:
    require(version_lifecycle, 'await _reuseSourceVersionDurablePartials(entry);', 'legacy mapping partial warmup')

catalog_test = read('packages/catalog/test/imported_library_store_test.dart')
for token in (
    'comic version page mapping parses verified time strictly',
    "'verifiedAt': 'not-a-date'",
    'throwsFormatException',
):
    require(catalog_test, token, 'mapping decode regression coverage')

check = read('tool/check.sh')
require(check, 'test_dev212_version_mapping_decode_freshness.py', 'release gate wiring')

print('dev.212 version mapping decode/freshness contract: OK')
