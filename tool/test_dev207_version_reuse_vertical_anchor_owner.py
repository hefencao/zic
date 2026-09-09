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

migration = read('apps/app/lib/demo_home_source_migration.dart')
for token in (
    'VerifiedArtifactReusePlan.matchResolvedRelated(',
    '_sourceResources.verifiedPageReuseIdentity(',
    "'stage': 'version-page-mapping-warmed'",
):
    require(migration, token, 'background confirmed-version reuse proof')
demo_home = read('apps/app/lib/demo_home.dart') + read('apps/app/lib/demo_home_reader_route.dart')
for token in (
    'await _restoreSourceVersionArtifactEquivalences(current);',
    '_scheduleVersionReuseWarmup(versionSource, current);',
):
    require(demo_home, token, 'Reader persisted-map reuse composition')
forbid(
    demo_home,
    'await _prepareSourceVersionArtifactReuse(current);',
    'synchronous source-resolved Reader reuse preparation',
)
forbid(migration, 'if (!discoveredNewVersion) return;', 'one-shot successor update gate')
forbid(migration, 'Future<void> _reconcileConfirmedSourceUpdateSignal(', 'superseded version-to-sourceUpdateAt mirroring')


reuse = read('packages/downloads/lib/src/artifact_cache_reuse.dart')
for token in (
    'typedef VerifiedPageReuseIdentityResolver',
    'static Future<VerifiedArtifactReusePlan> matchResolvedOffset({',
    'targetStart + overlap ~/ 2',
    'final required = anchorTargets.length == 1 ? 1 : 2;',
    'readerPageDownloadId(targetChapter, targetPages[targetIndex])',
):
    require(reuse, token, 'bounded verified temporary alias plan')

transport = read('packages/downloads/lib/src/source_resource_transport.dart')
for token in (
    'Future<String?> verifiedReuseIdentityFor(',
    'Future<String?> verifiedReuseIdentity(Uri locator) async {',
    'return verifiedComicResourceIdentity(resolved.request.uri);',
    'String? verifiedComicResourceIdentity(Uri uri)',
):
    require(transport, token, 'shared request-plan reuse identity')

reader = read('packages/reader/lib/src/reader_view.dart')
require(
    reader,
    'if (oldWidget.verticalStitch != widget.verticalStitch) {',
    'explicit vertical stitch anchor',
)
forbid(
    reader,
    'oldWidget.pageAspectRatios != widget.pageAspectRatios',
    'ratio-driven post-frame anchor restore',
)
for token in (
    'oldDevicePixelRatio:',
    'oldViewport:',
    '_scheduleVerticalAnchorRestore',
):
    require(reader, token, 'real viewport/geometry anchor owner')

reuse_test = read('packages/downloads/test/artifact_cache_reuse_test.dart')
for token in (
    'resolved anchor identities prepare temporary offset aliases',
    'resolved offset requires verified anchor agreement',
    'resource reuse identity accepts only strong media keys',
):
    require(reuse_test, token, 'reuse regression coverage')

check = read('tool/check.sh')
require(check, 'test_dev207_version_reuse_vertical_anchor_owner.py', 'release gate wiring')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 207:
    raise SystemExit('App build must be at least 207')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.207 version reuse / vertical anchor owner: OK')
