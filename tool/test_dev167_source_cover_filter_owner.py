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

source = read('apps/app/lib/source_browser.dart')
home = read('apps/app/lib/home_shell.dart')
catalog = read('packages/catalog/lib/src/source_catalog.dart')
adapter = read('packages/plugin_host/lib/src/runtime_source_adapter.dart')
source_test = read('apps/app/test/source_browser_test.dart')

# Browse projection changes are metadata changes. They must not globally bump
# every card's artwork resource identity. Explicit user refresh is the only
# page-level artwork reload token; URI changes are already observed locally by
# _RemoteImage.didUpdateWidget.
forbid(source, '_contentRevision', 'browse projection as artwork revision')
forbid(
    source,
    'Object.hash(_contentRevision, _artworkRetryRevision)',
    'global browse/artwork revision coupling',
)
require(source, 'reloadToken: _artworkRetryRevision', 'explicit artwork refresh token')
require(
    source,
    "'source-comic-owner:${source.sourceId}\\u0000${_stableSourceComicIdentity(source, comic.comicId)}'",
    'canonical source-card owner key',
)
require(source, 'CanonicalComicIdentitySource', 'canonical source-card identity capability')
require(
    source,
    'key: sourceComicCardKey(\n'
    '        source.sourceId,\n'
    '        _stableSourceComicIdentity(source, comic.comicId),\n'
    '      )',
    'canonical interaction key preserves the presentation subtree',
)
forbid(source, 'key: sourceComicCardKey(source.sourceId, comic.comicId)',
       'mutable raw interaction key below the canonical card owner')
require(
    home,
    'cacheComicId: _canonicalComicId(source.sourceId, comic.comicId)',
    'canonical browse artwork cache identity',
)
for token in (
    "'source-cover:${source.sourceId}\\u0000${_stableSourceComicIdentity(source, comic.comicId)}'",
    "'cover-load-start'",
    "'cover-source-ready'",
    "'cover-source-failed'",
    "'cover-first-frame'",
    "'cover-decode-failed'",
):
    require(source, token, 'source cover layered telemetry')

# Search filters remain source-owned opaque filters, but presentation belongs in
# the browse/category strip rather than inside search history UI. Latest precedes
# Popular when those standard sections are present, followed by the filter action.
for token in (
    'const comicSourceFilterActionKey',
    'const comicSourceFilterSheetKey',
    'List<SourceBrowseSection> _displaySections()',
    "if (id == 'latest' || label == 'latest' || label == '最新') return 0;",
    "if (id == 'popular' || label == 'popular' || label == '热门') return 1;",
    'Future<void> _openFilterSheet() async',
    "? '筛选'",
    'SourceSearchFilterKind.checkBox',
    'filterState: _filterState',
):
    require(source, token, 'source filter/category presentation')
for token in (
    'abstract interface class FilterableBrowsableComicSource',
    'Future<List<SourceSearchFilterNode>> loadSearchFilters()',
):
    require(catalog, token, 'catalog filter capability')
for token in (
    'Future<List<SourceSearchFilterNode>> loadSearchFilters() async',
    "'filterState': Map<String, Object?>.from(filterState)",
):
    require(adapter, token, 'runtime filter adapter')

# Widget contract follows the new visible placement and ordering.
for token in (
    'comicSourceFilterActionKey',
    'comicSourceFilterSheetKey',
    "find.byKey(comicSourceFilterKey('status'))",
    "find.text('应用')",
    "comicSourceCategoryKey('latest')",
    "comicSourceCategoryKey('popular')",
    'browse metadata refresh preserves canonical cover presentation owner',
    'expect(coverLoads, 1)',
    'expect(tester.state(image), same(originalImageState))',
):
    require(source_test, token, 'source browser widget contract')

version = re.search(r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 167:
    raise SystemExit('App build must be at least 167')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.167 source cover/filter ownership: OK')
