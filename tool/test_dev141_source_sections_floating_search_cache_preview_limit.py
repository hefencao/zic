#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f'{owner} missing dev.141 contract: {token}')

source = read('apps/app/lib/source_browser.dart')
catalog = read('packages/catalog/lib/src/source_catalog.dart')
cached = read('packages/catalog/lib/src/cached_comic_source.dart')
protocol = read('packages/plugin_host/lib/src/runtime_protocol.dart')
adapter = read('packages/plugin_host/lib/src/runtime_source_adapter.dart')
mihon = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt')
venera = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt')
prefs = read('apps/app/lib/app_preferences.dart')
settings = read('apps/app/lib/app_settings_screen.dart')
preview = read('apps/app/lib/comic_details_extras.dart')
home = read('apps/app/lib/home_shell_views.dart')
details = read('apps/app/lib/home_shell_source_compat.dart')
check = read('tool/check.sh')

for token in (
    'final class SourceBrowseSection',
    'abstract interface class SectionedBrowsableComicSource',
    'abstract interface class CachedSourceBrowseProjection',
):
    require(catalog, token, 'catalog browse contracts')
for token in (
    "'browse-sections'",
    'peekBrowsePage(',
    'refreshBrowsePage(',
    'forceRefresh: true',
):
    require(cached, token, 'catalog browse cache')
for token in ('loadBrowseSections', "'sectionId': sectionId"):
    require(protocol + adapter, token, 'runtime protocol')
for token in (
    '"sectionId" to "popular"',
    '"sectionId" to "latest"',
    'getLatestUpdates',
    'getFilterList',
):
    require(mihon, token, 'Mihon source sections')
for token in (
    '__zicBrowseSections(source)',
    "kind:'explore'",
    "kind:'category'",
    '__zicBrowseSectionValue(args.sectionId)',
):
    require(venera, token, 'Venera source sections')

for token in (
    'comicSourceSearchFabKey',
    'comicSourceSearchHistoryKey',
    'FloatingActionButton.small(',
    'this.searchHistory = const <String>[]',
    'SliverToBoxAdapter(',
    'child: _SourcePager(',
    '_sameBrowsePage(',
    'cachedChanged',
    'reloadToken: _artworkRetryRevision',
    '_comicSourceAccent(source)',
):
    require(source, token, 'source browser UI')
for forbidden in (
    'enum _ComicSourceCategory',
    'selectedCategory:',
    'onCategorySelected:',
    '_comicSourceCategoryContains',
):
    if forbidden in source:
        raise SystemExit(f'ecosystem-as-category path remains: {forbidden}')

for token in (
    '_detailsPreviewMaxItemsPerRow = 4',
    "'detailsPreviewMaxItemsPerRow'",
    '_sourceSearchHistory',
    'rememberSourceSearch(',
    'clearSourceSearchHistory(',
):
    require(prefs, token, 'preferences')
require(settings, 'readingPreviewMaxItemsPerRowKey', 'reading settings')
if not re.search(r"'version':\s*[4-9][0-9]*", prefs):
    raise SystemExit('preferences schema must remain at least v4')
for token in (
    'maxItemsPerRow: widget.previewMaxItemsPerRow',
    'final configuredMaximum = widget.maxItemsPerRow.clamp(1, 8).toInt()',
):
    require(preview + read('apps/app/lib/comic_details.dart'), token, 'preview layout')
for token in (
    'searchHistory: widget.preferences.sourceSearchHistory',
    'widget.preferences.rememberSourceSearch',
):
    require(home, token, 'source search composition')
require(details, 'widget.preferences.detailsPreviewMaxItemsPerRow', 'details composition')
require(check, 'test_dev141_source_sections_floating_search_cache_preview_limit.py', 'repository check')

version = re.search(r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 141:
    raise SystemExit('App build must be at least 141')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.141 source sections / floating search / SWR cache / preview limit: OK')
