#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f'{owner} missing dev.142 contract: {token}')


source = read('apps/app/lib/source_browser.dart')
preview = read('apps/app/lib/comic_details_extras.dart')
artwork = read('apps/app/lib/artwork_placeholder.dart')
home_cover = read('apps/app/lib/home_widgets.dart')
details_cover = read('apps/app/lib/comic_details.dart')
catalog = read('packages/catalog/lib/src/source_catalog.dart')
cached = read('packages/catalog/lib/src/cached_comic_source.dart')
protocol = read('packages/plugin_host/lib/src/runtime_protocol.dart')
adapter = read('packages/plugin_host/lib/src/runtime_source_adapter.dart')
mihon = read(
    'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt'
)
source_test = read('apps/app/test/source_browser_test.dart')
protocol_test = read('packages/plugin_host/test/runtime_protocol_test.dart')
architecture = read('docs/ARCHITECTURE.md')
spec = read('docs/SPEC.md')
check = read('tool/check.sh')

for token in (
    '_takePreviewRowIndices(',
    '_buildPreviewRow(',
    'availableItemWidth',
    'maximumSparseArea = referenceArea * 2.4',
    'width: maxWidth',
):
    require(preview, token, 'preview width utilization')
for forbidden in (
    'residual / (row.items.length - 1)',
    'final desiredScales = naturalRows.map',
):
    if forbidden in preview:
        raise SystemExit(f'superseded preview spacing remains: {forbidden}')

for token in (
    'final class ArtworkRetryController',
    'final class RecoverableArtworkImage',
    'unawaited(_effectiveProvider.evict())',
    'AppLifecycleState.resumed',
    'Duration(milliseconds: 180)',
    'Duration(milliseconds: 1200)',
):
    require(artwork, token, 'recoverable artwork')
for owner, text in (
    ('home cover', home_cover),
    ('source cover', source),
    ('details cover', details_cover),
):
    for token in (
        'ArtworkRetryController',
        'WidgetsBindingObserver',
        'RecoverableArtworkImage',
    ):
        require(text, token, owner)
if 'catchError((Object error, StackTrace' in source + home_cover + details_cover:
    raise SystemExit('typed artwork futures must use async/try-catch, not void catchError')

for token in (
    'WillPopScope(',
    'onVerticalDragStart: (_) => _collapseSearch()',
    'ScrollStartNotification',
    'UserScrollNotification',
    'FocusManager.instance.primaryFocus?.unfocus()',
):
    require(source, token, 'floating search gesture priority')

for token in (
    'final class SourceSearchFilterOption',
    'abstract interface class FilterableBrowsableComicSource',
    'selectedFilterIds',
):
    require(catalog + cached, token, 'catalog search filters')
for token in (
    'loadSearchFilters',
    "'filterIds': selectedFilterIds.toList(growable: false)",
):
    require(protocol + adapter, token, 'runtime search filters')
for token in (
    'getFilterList',
    'describeMihonSearchFilters',
    'applyMihonSearchFilters',
    '"checkbox" in kind',
    '"tristate" in kind',
    '"select" in kind',
    '"group" in kind',
    '"selected" to false',
):
    require(mihon, token, 'Mihon getFilterList projection')
if 'selected" to (filter.readBoolean' in mihon or 'selected" to (state ==' in mihon:
    raise SystemExit('Mihon source defaults must not become explicit ZIC filter selections')
for token in (
    'comicSourceFilterBarKey',
    'comicSourceFilterKey(option.filterId)',
    'FilterChip(',
    '_toggleSearchFilter(option, selected)',
):
    require(source, token, 'source filter chips')

refresh = read('apps/app/lib/app_pull_to_refresh.dart')
for token in (
    'RefreshIndicatorTriggerMode.onEdge',
    '_displacement = 72',
):
    require(refresh, token, 'shared pull refresh')
for token in (
    'AppPullToRefresh(',
    'onRefresh: () => _reload(forceRefresh: true)',
    'AlwaysScrollableScrollPhysics',
    'if (forceRefresh) _artworkRetryRevision++',
):
    require(source, token, 'source pull refresh')

for token in (
    "comicSourceFilterKey('status:check')",
    'tester.binding.handlePopRoute()',
    'find.byKey(comicSourcePullRefreshKey)',
    'firstRect.left - previewRect.left',
    'previewRect.right - firstRowLastRect.right',
):
    require(source_test, token, 'App owner tests')
for token in (
    'selectedFilterIds:',
    "decoded.arguments['filterIds']",
    'loadSearchFilters(',
):
    require(protocol_test, token, 'runtime protocol tests')

for token in (
    '预览行',
    '封面',
    '`getFilterList()`',
    '强制刷新',
):
    require(architecture + spec, token, 'stable documentation')
require(check, 'test_dev142_preview_cover_filter_pull_refresh.py', 'repository check')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 142:
    raise SystemExit('App build must be at least 142')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.142 preview width / cover recovery / filter / pull refresh: OK')
