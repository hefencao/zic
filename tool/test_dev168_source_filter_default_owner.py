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
catalog = read('packages/catalog/lib/src/source_catalog.dart')
cached = read('packages/catalog/lib/src/cached_comic_source.dart')
adapter = read('packages/plugin_host/lib/src/runtime_source_adapter.dart')
source_test = read('apps/app/test/source_browser_test.dart')
adapter_test = read('packages/plugin_host/test/runtime_source_adapter_test.dart')

# Filter visibility follows the actual source-owned schema. dev.169 supersedes
# dev.168's separate capability boolean while preserving the default-section
# ownership introduced here.
for token in (
    'Future<List<SourceSearchFilterNode>> loadSearchFilters();',
    'SourceSearchFilterState filterState',
):
    require(catalog, token, 'catalog search-filter schema')
for token in (
    'if (_sections.length > 1 || _searchFilters.isNotEmpty)',
    'if (_searchFilters.isEmpty) return;',
):
    require(source, token, 'filter action schema state')
for token in ('supportsSearchFilters', 'SourceSearchFilterOption'):
    forbid(catalog + cached + adapter + source, token, 'superseded filter capability')

# Browse cache is a data owner, not a navigation/default-state owner. Default
# selection and visual order must derive from the same ordering function.
forbid(
    source,
    'peekLatestBrowseProjection()',
    'latest cache restoring source browser UI state',
)
require(
    source,
    'final rawCached = cache?.peekBrowsePage(',
    'exact current request cache without requiring a visit snapshot',
)
require(
    source,
    '_canonicalSourceBrowsePage(source, rawCached)',
    'cached source restore must use canonical projection',
)
for token in (
    'final orderedSections = _orderedBrowseSections(sections);',
    ': (orderedSections.isEmpty ? null : orderedSections.first.sectionId);',
    'List<SourceBrowseSection> _orderedBrowseSections(',
    'List<SourceBrowseSection> _displaySections() =>\n      _orderedBrowseSections(_sections);',
):
    require(source, token, 'single section ordering/default owner')

# Widget coverage locks empty-schema hiding and first-column default focus.
for token in (
    'empty source filter schema does not invent a filter category',
    "expect(find.byKey(comicSourceFilterActionKey), findsNothing);",
    "tester.widget<ChoiceChip>(\n        find.byKey(comicSourceCategoryKey('latest')),",
    "expect(native.lastBrowseSection, 'latest');",
    'target section discovery retires an unresolved browse cache ',
):
    require(source_test, token, 'source browser widget contract')

version = re.search(
    r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$',
    read('apps/app/pubspec.yaml'),
    re.M,
)
if version is None or int(version.group(1)) < 168:
    raise SystemExit('App build must be at least 168')
android = re.search(
    r'^versionCode=(\d+)\s*$',
    read('apps/app/android/zic-version.properties'),
    re.M,
)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.168 source filter/default ownership: OK')
