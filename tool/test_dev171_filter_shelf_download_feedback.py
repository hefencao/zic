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

source_catalog = read('packages/catalog/lib/src/source_catalog.dart')
require(source_catalog, 'final bool useFilters;', 'cached filter-mode identity')
require(source_catalog, 'Empty state means "use the source-provided defaults"', 'empty override semantics')

cached = read('packages/catalog/lib/src/cached_comic_source.dart')
for token in (
    "useFilters ? 'filters' : 'section'",
    'if (filterable != null && useFilters)',
    'useFilters: true',
):
    require(cached, token, 'default-filter cache/request ownership')

adapter = read('packages/plugin_host/lib/src/runtime_source_adapter.dart')
require(adapter, "'useFilters': useFilters", 'runtime filter mode payload')
require(adapter, 'useFilters: true', 'filtered browse runtime mode')

protocol = read('packages/plugin_host/lib/src/runtime_protocol.dart')
for token in (
    'bool useFilters = false,',
    "'useFilters': useFilters",
    "optional: const <String>{'useFilters'}",
    "arguments['useFilters'] is! bool",
):
    require(protocol, token, 'runtime browse filter-mode protocol')

mihon = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt')
for token in (
    'val useFilters = arguments["useFilters"] as? Boolean ?: false',
    'if (!useFilters && query.isBlank())',
    'MihonFilterCodec.apply(',
):
    require(mihon, token, 'Mihon default FilterList route')

browser = read('apps/app/lib/source_browser.dart')
for token in (
    'bool _filterViewActive = false;',
    'filterViewActive: _filterViewActive',
    "'filterViewActive': _filterViewActive",
    '_filterViewActive = true;',
    '_filterViewActive = false;',
    'selected: _filterViewActive',
    'inShelf: widget.isInShelf?.call(source, comic) ?? false',
    'sourceComicShelfMarkerKey(',
    'sourceComicShelfDimKey(',
    "label: '已加入书架'",
):
    require(browser, token, 'source presentation ownership')
forbid(browser, 'return ActionChip(\n                            key: comicSourceFilterActionKey', 'non-selectable filter action')

home = read('apps/app/lib/demo_home.dart')
for token in (
    'enum _DownloadCompletionKind { chapter, wholeComic }',
    '_downloadCompletionBadges',
    '_pendingWholeComicCompletionBadges',
    '_recordChapterDownloadCompletion(',
    '_trackWholeComicDownloadCompletion(',
    '_clearDownloadCompletionBadge(',
    'ComicDownloadProgress.chapterComplete()',
    'ComicDownloadProgress.comicComplete()',
):
    require(home, token, 'download command completion feedback')
start = home.index('  ComicDownloadProgress? _downloadProgressForComic(')
end = home.index('\n  int get _nextCustomOrder', start)
progress_method = home[start:end]
forbid(progress_method, '.isComplete', 'cache-residency completion watermark')
forbid(progress_method, 'offlineChapters', 'persistent offline watermark')

widgets = read('apps/app/lib/home_widgets.dart')
for token in (
    'ComicDownloadProgressKind { active, chapterComplete, comicComplete }',
    'ComicDownloadProgress.chapterComplete',
    'ComicDownloadProgress.comicComplete',
    'Icons.check_circle_outline',
    'Icons.check_circle',
    'Colors.green',
):
    require(widgets, token, 'distinct completion badge presentation')
forbid(widgets, 'ComicDownloadProgress.offline', 'cache-residency completion model')

compat = read('apps/app/lib/demo_home_source_compat.dart')
for token in (
    '_recordChapterDownloadCompletion(',
    '_trackWholeComicDownloadCompletion(',
    '_clearDownloadCompletionBadge(source.sourceId, comic.comicId);',
    '_clearDownloadCompletionBadge(comic.sourceId, comic.comicId);',
):
    require(compat, token, 'download command/detail-consumption path')

views = read('apps/app/lib/demo_home_views.dart')
require(views, 'isInShelf: (source, comic) => _mergedPreferenceFor(', 'canonical shelf projection')

source_test = read('apps/app/test/source_browser_test.dart')
for token in (
    'Applying without edits is a real filter browse using the source defaults.',
    'source cards project shelf membership without owning it',
):
    require(source_test, token, 'source-browser regression tests')
lib_test = read('apps/app/test/library_ui_test.dart')
require(lib_test, 'download completion badges distinguish chapter and whole comic', 'download badge regression test')
cat_test = read('packages/catalog/test/cached_comic_source_test.dart')
require(cat_test, 'default filter browse has a distinct cache mode from source sections', 'filter cache regression test')
plugin_test = read('packages/plugin_host/test/runtime_source_adapter_test.dart')
require(plugin_test, "arguments['useFilters'], isTrue", 'runtime mode regression test')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 171:
    raise SystemExit('App build must be at least 171')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.171 filter view + shelf projection + download completion feedback: OK')
