#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f'{owner} missing dev.140 contract: {token}')

source = read('apps/app/lib/source_browser.dart')
plugins = read('apps/app/lib/external_plugin_repository_screen.dart')
plugin_model = read('apps/app/lib/external_plugin_repository_model.dart')
preview = read('apps/app/lib/comic_details_extras.dart')
details = read('apps/app/lib/comic_details.dart')
source_test = read('apps/app/test/source_browser_test.dart')
plugin_test = read('apps/app/test/external_plugin_repository_model_test.dart')
architecture = read('docs/ARCHITECTURE.md')
spec = read('docs/SPEC.md')
check = read('tool/check.sh')

for token in (
    'comicSourcePagerKey',
    'comicSourcePreviousPageKey',
    'comicSourceNextPageKey',
    'offset: requestedOffset',
    'limit: _pageSize',
    "'第 $page 页'",
):
    require(source, token, 'source browser')
for forbidden in (
    '_loadMore()',
    '_handleScroll()',
    'extentAfter <= 520',
    'enum _ComicSourceCategory { all, native, mihon, venera }',
):
    if forbidden in source:
        raise SystemExit(f'superseded source pagination/category path remains: {forbidden}')

for token in (
    'externalPluginInstalledLanguageBarKey',
    'externalPluginRepositoryLanguageBarKey',
    '_MihonLanguageFilterBar',
    'externalPluginLanguageCategories(',
    'externalPluginMatchesLanguage(',
):
    require(plugins, token, 'Mihon plugin UI')
for token in (
    'externalPluginLanguageCategory(',
    "return 'multi';",
    "'zh' => '中文'",
    "'und' => '未知语言'",
):
    require(plugin_model, token, 'Mihon language model')

for token in (
    'comicDetailsPreviewExpandKey',
    '_buildPreviewRow(',
    'math.sqrt(targetArea * aspect)',
    'math.sqrt(targetArea / aspect)',
    'MediaQuery.sizeOf(context).height * .8',
    'final firstRow = pages.first.rows.first;',
    'height: firstRow.height',
    'Icons.keyboard_arrow_down',
    'alignment: Alignment.center',
):
    require(details + preview, token, 'details preview')
for forbidden in (
    'width: 124',
    'height: 190',
    "label: Text(_expanded ? '收起' : '展开')",
    '_previewGridSlots',
):
    if forbidden in preview:
        raise SystemExit(f'legacy preview layout remains: {forbidden}')

for token in (
    'source-owned sections floating search and bottom pager preserve order',
    'lessThanOrEqualTo(1.2)',
    'comicDetailsPreviewExpandKey',
):
    require(source_test, token, 'App owner tests')
require(plugin_test, 'Mihon plugins derive stable language categories', 'plugin model tests')

for token in (
    '等目标面积',
    '面积比不超过 1.2',
):
    require(architecture + spec, token, 'stable documentation')
require(check, 'test_dev140_source_paging_mihon_language_equal_area_preview.py', 'repository check')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 140:
    raise SystemExit('App build must be at least 140')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.140 source paging / Mihon language / equal-area preview: OK')
