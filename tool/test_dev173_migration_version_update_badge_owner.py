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

browser = read('apps/app/lib/source_browser.dart')
for token in (
    'sourceComicShelfMarkerKey(',
    'alignment: Alignment.topLeft',
    'Icons.library_books',
    "label: '已加入书架'",
    'sourceComicUpdateMarkerKey(',
    'alignment: Alignment.topRight',
    "label: '漫画有更新'",
    'hasUpdate',
    'onOpenUpdate',
):
    require(browser, token, 'source-card shelf/update projection')
forbid(browser, 'Icons.collections_bookmark,\n                            size: 16', 'bookmark-shaped shelf marker')

views = read('apps/app/lib/demo_home_views.dart')
for token in (
    'hasUpdate: _sourceComicHasUpdate',
    'onOpenUpdate: _openSourceUpdateForSummary',
):
    require(views, token, 'Home-owned update projection wiring')

migration = read('apps/app/lib/demo_home_source_migration.dart')
for token in (
    '_sourceComicHasUpdate(',
    'saved.sourceUpdateAt != null',
    '_openSourceUpdateForSummary(',
    '_loadSourceVersionState(',
    '_librarySession.versionBaselines.latestKnownHeadFor(',
    '...state.successors,',
    '...state.predecessors,',
    '_viewSourceVersion(',
    '_selectSourceMigrationTarget(',
    '_selectConfirmedSourceVersion(',
    '_openSourceMigrationForSummary(',
    '_openSourceMigration(',
    "child: const Text('查看')",
    "version.isPredecessor ? '迁移旧版状态' : '迁移到此版本'",
    "label: const Text('已确认同源版本')",
    'final page = await choice.source.browse(query: comic.title, limit: 12);',
    'showSourceMigrationComparison(',
    'ComicSourceMigrationPlan.build(',
    'await _savePreference(mergedPreference);',
    'final neutral = ComicPreference(',
    'await _library.saveComicPreference(neutral);',
    '_librarySession.replacePreference(neutral);',
):
    require(migration, token, 'unified migration/version/update ownership')
forbid(migration, 'await _library.saveComicPreference(mergedPreference);', 'migration preference bypass')

# Same-source confirmed relations must not be inferred from title search. The
# title browse remains only the cross-source branch after the explicit
# same-source version branch.
version_branch = migration.index('if (choice.versions)')
search_branch = migration.index('final page = await choice.source.browse', version_branch)
if search_branch <= version_branch:
    raise SystemExit('cross-source title search must follow confirmed same-source branch')

compat = read('apps/app/lib/demo_home_source_compat.dart')
for token in (
    'onMigrateSource: () {',
    'return _openSourceMigrationForSummary(active, comic);',
    "onMigrateSource: resolvedSource == null ||\n                  comic.sourceId == 'local-folder'",
    ': () => _openSourceMigration(comic)',
):
    require(compat, token, 'detail migration composition')

details = read('apps/app/lib/comic_details.dart') + read('apps/app/lib/comic_details_interactions.dart')
for token in (
    'comicDetailsMigrateKey',
    'ComicDetailsSourceMigrator',
    'onMigrateSource',
    "tooltip: '迁移漫画源'",
    'Icons.swap_horiz',
):
    require(details, token, 'detail general migration action')

source_test = read('apps/app/test/source_browser_test.dart')
for token in (
    'source cards project shelf membership without owning it',
    'Icons.library_books',
    'source card update marker is projected separately from shelf',
    'sourceComicUpdateMarkerKey',
    'Icons.priority_high',
):
    require(source_test, token, 'source-card widget regression coverage')

check = read('tool/check.sh')
require(check, 'test_dev173_migration_version_update_badge_owner.py', 'release gate wiring')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 173:
    raise SystemExit('App build must be at least 173')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.173 migration / version / update badge ownership: OK')
