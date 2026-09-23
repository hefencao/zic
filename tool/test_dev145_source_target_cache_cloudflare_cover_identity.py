#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f'{owner} missing dev.145 contract: {token}')

catalog = read('packages/catalog/lib/src/source_catalog.dart')
cached = read('packages/catalog/lib/src/cached_comic_source.dart')
source = read('apps/app/lib/source_browser.dart')
home = read('apps/app/lib/home_widgets.dart')
demo = read('apps/app/lib/home_shell.dart')
views = read('apps/app/lib/home_shell_views.dart')
details = read('apps/app/lib/comic_details.dart')
catalog_test = read('packages/catalog/test/cached_comic_source_test.dart')
source_test = read('apps/app/test/source_browser_test.dart')
check = read('tool/check.sh')

for token in (
    'final class CachedSourceBrowseSnapshot',
    'CachedSourceBrowseSnapshot? peekLatestBrowseProjection()',
):
    require(catalog, token, 'catalog browse projection')
for token in (
    'CachedSourceBrowseSnapshot? _latestBrowseProjection',
    '_latestBrowseProjection = CachedSourceBrowseSnapshot(',
    'peekLatestBrowseProjection()',
):
    require(cached, token, 'cached source latest projection')
for token in (
    'String? _projectionSourceId',
    '_restoreTargetProjection(_activeSource)',
    'final cached = remembered == null',
    'final projectionMatchesSource = _projectionSourceId == source.sourceId',
    'allowVerificationFallback',
    'failure.shouldAutoOpenVerification',
    'verificationUri: failure.verificationUri',
):
    require(source, token, 'source target projection and verification')
if 'peekLatestBrowseProjection()' in source:
    raise SystemExit(
        'source browser must not let latest catalog projection restore UI defaults'
    )
if 'avatar: Icon(' in source:
    raise SystemExit('source switcher still wastes chip width on runtime icons')
for token in (
    'latest browse projection follows the target source request identity',
    "forced retry falls back to source WebView once",
):
    require(catalog_test + source_test, token, 'owner tests')

for token in (
    'required this.coverIdentity',
    'cacheIdentity: coverIdentity',
    'StableArtworkImage(',
):
    require(home, token, 'stable Home artwork presentation')
for stale in (
    '_scheduleFirstFrameWatchdog()',
    '_decodeRecoveryGeneration',
    'ArtworkRetryController',
    'RecoverableArtworkImage',
):
    if stale in home:
        raise SystemExit(f'Home retains superseded artwork recovery: {stale}')
for stale in (
    'final Map<String, Future<EncodedResourceSource>> _coverSourceInflight',
    '_coverRecoverySourceLoaderForComic(',
):
    if stale in demo:
        raise SystemExit(f'App retains superseded cover owner: {stale}')
for token in (
    "'home-history' : 'home-update'",
    'final coverIdentity = _canonicalComicKey(',
    'telemetryOwners.add(presentationIdentity)',
):
    require(views, token, 'canonical Home cover owners')
for token in (
    'if (candidate is! ComicPreviewSource) return null;',
    'return candidate as ComicPreviewSource;',
    'if (candidate is! ComicCommentSource) return null;',
    'return candidate as ComicCommentSource;',
):
    require(details, token, 'detail capability compile closure')
require(check, 'test_dev145_source_target_cache_cloudflare_cover_identity.py', 'repository check')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 145:
    raise SystemExit('App build must be at least 145')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.145 target cache / Cloudflare / cover identity contract: OK')
