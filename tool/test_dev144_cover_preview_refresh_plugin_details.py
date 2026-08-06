#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f'{owner} missing dev.144 contract: {token}')

artwork = read('apps/app/lib/artwork_placeholder.dart')
home = read('apps/app/lib/home_widgets.dart')
demo = read('apps/app/lib/demo_home.dart')
gateway = read('apps/app/lib/source_resource_gateway.dart')
cached = read('packages/catalog/lib/src/cached_comic_source.dart')
details = read('apps/app/lib/comic_details.dart')
interactions = read('apps/app/lib/comic_details_interactions.dart')
preview = read('apps/app/lib/comic_details_extras.dart')
refresh = read('apps/app/lib/app_pull_to_refresh.dart')
source = read('apps/app/lib/source_browser.dart')
library_test = read('apps/app/test/library_ui_test.dart')
source_test = read('apps/app/test/source_browser_test.dart')
architecture = read('docs/ARCHITECTURE.md')
spec = read('docs/SPEC.md')
check = read('tool/check.sh')

for token in (
    'onRecoveryExhausted',
    '_exhaustionReported',
    'scheduleMicrotask(() => widget.onRecoveryExhausted?.call())',
):
    require(artwork, token, 'decode recovery exhaustion')
for token in (
    'recoveryCoverSource',
    '_recoverEncodedSource()',
    '_encodedRecoveryAttempted',
    '_decodeRecoveryGeneration',
    '_firstFrameTimeout = Duration(milliseconds: 2500)',
    '_scheduleFirstFrameWatchdog()',
):
    require(home, token, 'home cover source recovery')
for token in (
    'bool forceRefresh = false',
    'forceRefresh: forceRefresh',
):
    require(cached + gateway + demo, token, 'encoded artwork force refresh')
require(demo, '_coverRecoverySourceLoaderForComic(', 'home recovery composition')

for token in (
    'required this.complete',
    'if (row.complete || row.items.first.area <= maximumSparseArea)',
    'maximumSparseArea = referenceArea * 2.4',
    'MediaQuery.sizeOf(context).height * .9',
    'if (row.complete || row.items.first.area <= maximumSparseArea)',
):
    require(preview, token, 'preview width utilization')
require(interactions, 'EdgeInsets.fromLTRB(0, 8, 0, 0)', 'preview full-width sliver')

for token in (
    'final class AppPullToRefresh extends StatefulWidget',
    'final Future<bool> Function() onRefresh',
    '_displacement = 72',
    'top: _displacement',
    'Icons.check',
    'Icons.close',
):
    require(refresh, token, 'shared refresh component')
for token in (
    'resultKey: comicDetailsRefreshStateKey',
    'onRefresh: widget.onRefresh',
):
    require(interactions, token, 'details refresh usage')
for token in (
    'comicSourceRefreshStateKey',
    'resultKey: comicSourceRefreshStateKey',
    'Future<bool> _reload(',
):
    require(source, token, 'source refresh usage')
for forbidden in ('_DetailsRefreshBadge', '_DetailsRefreshState'):
    if forbidden in interactions:
        raise SystemExit(f'details retains duplicate refresh UI: {forbidden}')

for token in (
    'Future<BrowsableComicSource> _sourceForOperation() async',
    'Duration(seconds: 5)',
    'final source = await _sourceForOperation();',
    'final cachedComic = _library.sourceManifest?.comic',
    'Future<ComicPreviewPage> _loadRemotePreview',
    'Future<ComicCommentPage> _loadRemoteComments',
    'invalidateCachedComic(source, comicId)',
):
    require(details, token, 'active plugin source resolution')
require(details, '_withoutCompatibilityFallback(', 'generic chapter normalization')
for token in (
    'reconcileComicDetailsSourceChapters(',
    '!isCompatibilityFallback(entry.chapter.chapterId)',
):
    require(demo, token, 'compatibility chapter removal')
require(library_test, 'real source chapters remove compatibility fallback chapters', 'chapter owner test')
require(demo, 'isCompatibilityFallback: isSyntheticMihonChapterIdentity', 'composition compatibility injection')

for token in (
    "Text('简介'",
    'margin: EdgeInsets.zero',
    'surfaceContainerLow',
):
    require(details + preview, token, 'details layout')
require(preview, "RegExp(r'<br\\s*/?>'", 'comment line-break normalization')
for token in ('lessThanOrEqualTo(2.4)', 'lessThanOrEqualTo(540)'):
    require(source_test, token, 'preview owner test')
for token in ('稀疏末行', '90%', '统一刷新', '首帧 watchdog'):
    require(architecture + spec, token, 'stable documentation')
require(check, 'test_dev144_cover_preview_refresh_plugin_details.py', 'repository check')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 144:
    raise SystemExit('App build must be at least 144')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.144 cover / preview / refresh / plugin details contract: OK')
