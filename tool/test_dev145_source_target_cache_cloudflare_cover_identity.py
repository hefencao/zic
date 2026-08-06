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
demo = read('apps/app/lib/demo_home.dart')
views = read('apps/app/lib/demo_home_views.dart')
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
    'final latest = cache?.peekLatestBrowseProjection()',
    'final projectionMatchesSource = _projectionSourceId == source.sourceId',
    'allowVerificationFallback',
    'scheduleMicrotask(() => unawaited(_recoverSourceAccess(source)))',
):
    require(source, token, 'source target projection and verification')
if 'avatar: Icon(' in source:
    raise SystemExit('source switcher still wastes chip width on runtime icons')
for token in (
    'latest browse projection follows the target source request identity',
    "forced retry falls back to source WebView once",
):
    require(catalog_test + source_test, token, 'owner tests')

for token in (
    'this.interactionKey',
    'key: interactionKey',
    'bool _streamWatchdogAttempted = false',
    'setState(() => _decodeRecoveryGeneration++)',
    'Actual decode exhaustion is the only',
):
    require(home, token, 'cover presentation identity')
watchdog = home[home.index('void _scheduleFirstFrameWatchdog()'):home.index('void _reportFirstFrame()')]
if '_recoverEncodedSource()' in watchdog or '_restartLoadWithReset()' in watchdog:
    raise SystemExit('no-frame watchdog still invalidates encoded cover source')
for token in (
    'final Map<String, Future<EncodedResourceSource>> _coverSourceInflight',
    'A failed future must be removed immediately',
):
    require(demo, token, 'cover source join')
for token in (
    "'home-history' : 'home-update'",
    'interactionKey: resume == null',
    'telemetryOwners.add(comic.identity)',
):
    require(views, token, 'stable Home cover owners')
for token in (
    'candidate is ComicPreviewSource ? candidate : null',
    'candidate is ComicCommentSource ? candidate : null',
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
