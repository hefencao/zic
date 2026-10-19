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

views = read('apps/app/lib/home_shell_views.dart')
for token in (
    'hasUpdate: _sourceComicHasUpdate',
    'onOpenUpdate: _openSourceUpdateForSummary',
):
    require(views, token, 'Home-owned update projection wiring')

migration = read('apps/app/lib/home_shell_source_migration.dart')
transaction = read('apps/app/lib/home_source_migration_transaction.dart')
for token in (
    '_sourceComicHasUpdate(',
    'saved.sourceUpdateAt != null',
    '_openSourceUpdateForSummary(',
    '_loadSourceVersionState(',
    '_librarySession.versionBaselines.latestKnownHeadFor(',
    '_viewSourceVersion(',
    '_selectSourceMigrationTarget(',
    '_openSourceMigrationForSummary(',
    '_openSourceMigration(',
    'webUriFor: (version) => _sourceComicWebUri(currentSource, version.comicId)',
    'ComicTitleSearchPage(',
    'versionState: versionState',
    '_SourceMigrationVersionNotice(',
    'future: initial.backgroundRefresh',
    '...state.successors, ...state.predecessors',
    'ConfirmedSourceVersionList(',
    'onSelectNativeId:',
    'ModalRoute.of(context)?.isCurrent != true',
    'await route.completed;',
    'showSourceMigrationComparison(',
    'ComicSourceMigrationPlan.build(',
):
    require(migration, token, 'unified migration/version/update ownership')

presentation = read('apps/app/lib/source_migration_compare.dart')
for token in (
    'showConfirmedSourceVersionSelection(',
    'future: backgroundRefresh,',
    "child: const Text('查看')",
    "? '迁移旧版状态' : '迁移到此版本'",
    'webUriFor(version).toString()',
    '(version: version, viewOnly: true)',
    'versions: snapshot.data ?? versions',
    '(version: version, viewOnly: false)',
):
    require(presentation, token, 'readonly confirmed-version presentation')
for token in (
    'final class HomeSourceMigrationTransaction',
    'await savePreference(mergedPreference);',
    'final neutral = ComicPreference(',
    'await session.persistPreference(neutral);',
    'await session.persistReadState(',
):
    require(transaction, token, 'confirmed migration transaction ownership')
forbid(
    migration + transaction,
    'await _library.saveComicPreference(mergedPreference);',
    'migration preference bypass',
)

# Search selects exact candidates; only the source/durable authority supplies
# confirmed versions. The selector never commits relationships or migration.
version_ui = migration.split('final class _SourceMigrationVersionNotice', 1)[1]
version_ui = version_ui.split('extension _HomeShellSourceMigration', 1)[0]
forbid(version_ui, '.browse(', 'title-inferred confirmed versions')
selector = migration.split('Future<_SourceMigrationSelection?> _selectSourceMigrationTarget(', 1)[1]
selector = selector.split('Future<void> _openSourceMigrationForSummary(', 1)[0]
require(selector, 'comicId: candidate.comicId', 'exact selected native identity')
for token in ('ComicVersionRelation(', 'saveComicVersionRelation(', 'executeConfirmed('):
    forbid(selector, token, 'selection UI write authority')

compat = read('apps/app/lib/home_shell_source_compat.dart')
for token in (
    'onMigrateSource: ({versionState}) {',
    'return _openSourceMigrationForSummary(active, comic, versionState: versionState);',
    "onMigrateSource: resolvedSource == null ||",
    "comic.sourceId == 'local-folder'",
    ': ({versionState}) => _openSourceMigration(comic, versionState: versionState)',
):
    require(compat, token, 'detail migration composition')

details = read('apps/app/lib/comic_details.dart') + read('apps/app/lib/comic_details_interactions.dart')
for token in (
    'comicDetailsMigrateKey',
    'ComicDetailsSourceMigrator',
    'onMigrateSource',
    "tooltip: '迁移漫画源'",
    'Icons.swap_horiz',
    'await widget.onOpenMigration!(versionState: _state);',
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

version = re.search(r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 173:
    raise SystemExit('App build must be at least 173')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.173 migration / version / update badge ownership: OK')
