#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f'{owner} missing dev.146 contract: {token}')

def forbid(text: str, token: str, owner: str) -> None:
    if token in text:
        raise SystemExit(f'{owner} retains obsolete dev.146 path: {token}')

catalog = read('packages/catalog/lib/src/source_catalog.dart')
memory = read('packages/catalog/lib/src/imported_library_store.dart')
sqlite = read('packages/storage/lib/src/sqlite_imported_library_store.dart')
details = read('apps/app/lib/comic_details.dart') + read('apps/app/lib/comic_details_interactions.dart')
composition = read('apps/app/lib/demo_home_source_compat.dart')
migration = read('apps/app/lib/demo_home_source_migration.dart')
reader = read('apps/app/lib/demo_home_reader_route.dart')
prefs = read('apps/app/lib/app_preferences.dart')
identity = read('apps/app/lib/demo_home_catalog_identity.dart')
home = read('apps/app/lib/demo_home.dart')
cookie = read('packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidBrowserCookieSession.kt')
cookie_jar = read('packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCookieJar.kt')
mihon = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt')
architecture = read('docs/ARCHITECTURE.md')
check = read('tool/check.sh')

for token in (
    'Future<List<ComicVersionRelation>> listComicVersionSuccessors(',
    'String predecessorComicId,',
):
    require(catalog, token, 'version relation contract')
require(memory, 'listComicVersionSuccessors(', 'memory relation store')
for token in ('listComicVersionSuccessors(', 'comic_version_relation_predecessor'):
    require(sqlite, token, 'sqlite relation store')

for token in (
    'if (candidate is! ComicPreviewSource) return null;',
    'return candidate as ComicPreviewSource;',
    'if (candidate is! ComicCommentSource) return null;',
    'return candidate as ComicCommentSource;',
):
    require(details, token, 'explicit capability cast')

for stale in (
    '_withoutSyntheticMihonFallback',
    '_removePersistedSyntheticChapters',
    'reconcileComicDetailsSourceChapters',
):
    forbid(identity + home + details, stale, 'obsolete App synthetic chapter cleanup')

for token in (
    'final class ComicDetailsVersionState',
    'comicDetailsVersionActionKey',
    "child: Text('查看$label')",
    "child: const Text('迁移')",
):
    require(details, token, 'detail version view/migration actions')
for token in (
    '_loadSourceVersionState(',
    '_storedSourceSuccessors(',
    '_storedSourcePredecessors(',
    '_viewSourceVersion(',
    '_migrateSourceVersion(',
    'sourceVersionViewIdentity(',
):
    require(migration, token, 'same-source version state and routing')
for stale in (
    "tooltip: '迁移漫画源'",
    "tooltip: '查看同源版本'",
    "groupLabel('旧版')",
    "groupLabel('新版')",
):
    forbid(details + migration, stale, 'obsolete version AppBar/list UI')

for token in (
    '_ReaderComicVersionNoticeGate',
    'listComicVersionSuccessors(',
    '发现同源新版本，可在漫画详情页查看更新',
):
    require(reader, token, 'Reader first update notice')
for token in (
    'comicVersionNoticeIdentity(',
    'hasAcknowledgedComicVersionNotice(',
    'acknowledgeComicVersionNotice(',
    "'version':",
):
    require(prefs, token, 'version notice acknowledgement')

for token in (
    'fun resetAllImports()',
    'importedSnapshotRevisions.clear()',
):
    require(cookie, token, 'browser cookie handoff reset')
require(cookie_jar, 'fun resetBrowserSnapshotImports()', 'browser handoff public reset boundary')
require(mihon, 'AndroidCookieJar.resetBrowserSnapshotImports()', 'Mihon browser handoff')

for token in (
    'raw locator identity',
    'canonical comparison identity',
    'version relation identity',
    'sequence-only',
):
    require(architecture, token, 'architecture identity taxonomy')
require(check, 'test_dev146_identity_version_notice_synthetic_cloudflare.py', 'repository check')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 146:
    raise SystemExit('App build must be at least 146')
print('dev.146 identity / version notice / synthetic / Cloudflare contract: OK')
