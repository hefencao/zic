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

# Capability and one schema load result are different state dimensions. The
# category action must follow capability, not whether the current list is empty.
for token in (
    'bool get supportsSearchFilters;',
    'Future<List<SourceSearchFilterOption>> loadSearchFilters();',
):
    require(catalog, token, 'catalog search-filter capability')
require(
    adapter,
    'bool get supportsSearchFilters =>\n      _format == ExternalComicPluginFormat.mihonExtension;',
    'runtime format filter capability',
)
require(cached, 'return filterable?.supportsSearchFilters ?? false;',
        'cached capability delegation')
for token in (
    'bool _supportsSearchFilters = false;',
    'if (_sections.length > 1 || _supportsSearchFilters)',
    '(_supportsSearchFilters ? 1 : 0)',
    'if (!_supportsSearchFilters) return;',
    '当前漫画源未提供可用筛选项',
):
    require(source, token, 'filter action capability state')
forbid(
    source,
    '(_searchFilters.isEmpty ? 0 : 1)',
    'filter list as action capability',
)

# Browse cache is a data owner, not a navigation/default-state owner. Default
# selection and visual order must derive from the same ordering function.
forbid(
    source,
    'peekLatestBrowseProjection()',
    'latest cache restoring source browser UI state',
)
require(
    source,
    'final cached = remembered == null',
    'only explicit in-session state may use exact cached projection',
)
for token in (
    'final orderedSections = _orderedBrowseSections(sections);',
    ': (orderedSections.isEmpty ? null : orderedSections.first.sectionId);',
    'List<SourceBrowseSection> _orderedBrowseSections(',
    'List<SourceBrowseSection> _displaySections() =>\n      _orderedBrowseSections(_sections);',
):
    require(source, token, 'single section ordering/default owner')

# Widget coverage locks visible empty-schema filter capability and first-column
# default focus. A future custom order only needs to replace the ordering owner.
for token in (
    '(source as FilterableBrowsableComicSource).supportsSearchFilters',
    'isFalse',
    'isTrue',
):
    require(adapter_test, token, 'runtime filter capability tests')

for token in (
    'filter capability keeps the category action visible with an empty schema',
    'supportsSearchFilters: true',
    '当前漫画源未提供可用筛选项',
    "tester.widget<ChoiceChip>(\n        find.byKey(comicSourceCategoryKey('latest')),",
    "expect(native.lastBrowseSection, 'latest');",
):
    require(source_test, token, 'source browser widget contract')

version = re.search(
    r'^version:\s*0\.31\.0\+(\d+)\s*$',
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
