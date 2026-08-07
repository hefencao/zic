#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f'{owner} missing dev.147 contract: {token}')

def forbid(text: str, token: str, owner: str) -> None:
    if token in text:
        raise SystemExit(f'{owner} retains obsolete dev.147 path: {token}')

reader = read('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
details = read('apps/app/lib/comic_details.dart') + read('apps/app/lib/comic_details_interactions.dart')
source_test = read('apps/app/test/source_browser_test.dart')
reader_test = read('apps/app/test/reader_controls_test.dart')
source_wrapper = read('apps/app/lib/source_browser.dart')
composition = read('apps/app/lib/demo_home_source_compat.dart')
migration = read('apps/app/lib/demo_home_source_migration.dart')
identity = read('apps/app/lib/demo_home_catalog_identity.dart')
runtime_adapter = read('packages/plugin_host/lib/src/runtime_source_adapter.dart')
mihon = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt')
cloudflare = read('packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCloudflareInterceptor.kt')
compat_cf = read('packages/plugin_host_bridge/android/src/mihonRuntimeCommon/kotlin/dev/zic/mihonruntime/RuntimeCloudflareInterceptor.kt')
chapter_test = read('packages/plugin_host_bridge/android/src/test/kotlin/dev/zic/pluginhost/MihonHostAbiTest.kt')
architecture = read('docs/ARCHITECTURE.md')
spec = read('docs/SPEC.md')
check = read('tool/check.sh')

for token in (
    'ReadingProgress? _pendingProgress;',
    'Future<void>? _progressDrain;',
    'Future<void> _drainReaderProgress() async',
    'while (_pendingProgress != null)',
    'Future<bool> _flushProgressBeforePop() async',
    'while (_pendingProgress != null || _progressDrain != null)',
    'onWillPop: _flushProgressBeforePop',
    'AppLifecycleState.inactive',
    'AppLifecycleState.paused',
    'AppLifecycleState.detached',
):
    require(reader, token, 'Reader progress checkpoint queue')
require(details, 'final refreshed = await widget.reloadLibrary(refreshContent: false);', 'details history refresh after Reader')

require(mihon, 'import dev.zic.network.AndroidBrowserCookieSession', 'Mihon cookie session compile closure')
for token in (
    'deduplicateMihonStartReadingEntries(',
    '"开始阅读"',
    '"开始阅读章节"',
    'sourceChapters = deduplicateMihonStartReadingEntries(',
):
    require(mihon, token, 'Mihon independent start-reading action de-duplication')
for stale in (
    '_withoutSyntheticMihonFallback',
    '_removePersistedSyntheticChapters',
    'reconcileComicDetailsSourceChapters',
    'isCompatibilityFallback:',
):
    forbid(details + source_wrapper + composition + identity, stale, 'App synthetic chapter cleanup')
require(chapter_test, 'fun removesOnlyAStandaloneStartReadingActionBesideRealChapters()', 'Mihon start-reading owner test')

for stale in (
    'isSyntheticMihonChapterIdentity',
    'isCurrentSyntheticMihonChapterIdentity',
    '_decodeMihonChapterIdentity',
):
    forbid(runtime_adapter, stale, 'removed App-facing synthetic chapter cleanup API')

for token in (
    'class SourceVerificationRequiredException(',
    'if (statusCode !in CLOUDFLARE_STATUS_CODES) return false',
    'mitigatedHeader?.equals("challenge", ignoreCase = true)',
    'val strongChallengeMarker = body.contains("challenge-platform")',
    'if (!body.contains("just a moment")) return false',
    'return cloudflareServer || cloudflareBranding',
):
    require(cloudflare, token, 'typed Cloudflare classification')
for token in (
    'private val delegate = AndroidCloudflareInterceptor(',
    'delegate.intercept(chain)',
):
    require(compat_cf, token, 'single Cloudflare classifier compatibility wrapper')
for stale in (
    'CountDownLatch',
    'CLOUDFLARE_WAIT_SECONDS',
    'Cloudflare verification failed; open the source login page and retry',
):
    forbid(compat_cf, stale, 'hidden/untyped Cloudflare verification')
for token in (
    'current is SourceVerificationRequiredException',
    '!verificationRequired &&',
):
    require(mihon, token, 'typed verification envelope mapping')
for stale in (
    'contains("cloudflare verification failed"',
    'contains("just a moment"',
):
    forbid(mihon, stale, 'message-based verification classification')

for token in (
    'final class ComicDetailsVersionState',
    'List<SourceComicVersion> successors',
    'List<SourceComicVersion> predecessors',
    "final label = successor ? '新版本' : '旧版本';",
    "child: Text('查看$label')",
    "child: const Text('迁移')",
    'showDialog<SourceComicVersion>',
):
    require(details, token, 'Vibe-style version detail UI')
for token in (
    '_storedSourceSuccessors(',
    '_storedSourcePredecessors(',
    '_viewSourceVersion(',
    '_migrateSourceVersion(',
    'resolveCanonicalAlias: false',
    'sourceVersionViewIdentity(',
    '_applySourceMigration(',
):
    require(migration, token, 'raw-version view and old migration confirmation flow')
for token in (
    'resolveCanonicalAlias: resolveCanonicalAlias',
    'sameComicIdentity: resolveCanonicalAlias',
):
    require(composition, token, 'raw version detail route identity')

for stale in (
    '_selectSourceMigrationTarget(',
    '_openSourceVersions(',
    '_openSourceVersionsForSummary(',
    '_openSourceMigrationForSummary(',
    '_openSourceMigration(',
):
    forbid(migration, stale, 'obsolete version/migration entry path')

for stale in (
    "tooltip: '迁移漫画源'",
    "tooltip: '查看同源版本'",
    "groupLabel('旧版')",
    "groupLabel('新版')",
):
    forbid(details + migration, stale, 'obsolete version buttons/list')

for token in (
    'raw locator identity',
    'temporary route identity',
    'multiple versions',
    'Reader progress',
    'sourceVerificationRequired',
):
    require(architecture + spec, token, 'architecture/specification update')

for token in (
    "details separates same-source version view and migration",
    "find.byKey(details.comicDetailsVersionViewKey)",
    "find.byKey(details.comicDetailsVersionMigrateKey)",
    "find.text('查看新版本')",
    "find.text('有新版本'), findsNothing",
):
    require(source_test, token, 'version UI owner test')
for token in (
    'reader waits for the final progress checkpoint before pop',
    'final pop = tester.binding.handlePopRoute()',
    'firstWrite.complete()',
    'expect(writes.last.pageIndex, 2)',
):
    require(reader_test, token, 'Reader progress owner test')

require(check, 'test_dev147_reader_progress_start_action_version_ui_verification.py', 'repository check')
require(check, 'test_cloudflare_classifier_kotlin_compile.py', 'Cloudflare compile check')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 147:
    raise SystemExit('App build must be at least 147')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.147 progress / start action / version UI / verification contract: OK')
