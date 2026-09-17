#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.90 tokens: {missing}')


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains forbidden dev.90 tokens: {found}')


runtime_store = (
    'packages/network_bridge/android/src/runtime/kotlin/'
    'dev/zic/network/NetworkBrowserSnapshotStore.kt'
)
main_store = (
    'packages/network_bridge/android/src/main/kotlin/'
    'dev/zic/network/NetworkBrowserSnapshotStore.kt'
)
if not (ROOT / runtime_store).is_file():
    raise SystemExit('FAIL: browser snapshot store is absent from runtime source set')
if (ROOT / main_store).exists():
    raise SystemExit('FAIL: browser snapshot store still has a competing main-source copy')

require(
    'packages/network_bridge/android/build.gradle',
    'main.java.srcDir "src/runtime/kotlin"',
)
require(
    'packages/plugin_host_bridge/android/build.gradle',
    'networkRuntimeSources = file("../../network_bridge/android/src/runtime/kotlin")',
)
require(
    runtime_store,
    'internal object NetworkBrowserSnapshotStore',
    'same-directory temporary file plus rename',
)
require(
    'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt',
    '"dev.zic.network.NetworkBrowserSnapshotStore"',
)
require(
    'packages/network_bridge/android/consumer-rules.pro',
    '-keep class dev.zic.network.NetworkBrowserSnapshotStore { *; }',
)
require(
    'tool/test_external_login_bridge.py',
    'AndroidBrowserCookieSession.kt',
    'AndroidCookieJar.kt',
    'NetworkBrowserSnapshotStore.kt',
)

require(
    'packages/catalog/lib/src/source_catalog.dart',
    'abstract interface class CanonicalComicIdentitySource',
    'equivalence key',
)
require(
    'packages/catalog/lib/src/library_comic.dart',
    'collapseCanonicalLibraryComics',
    'preferredLibraryComicAlias',
    'keeps\n/// its original source',
)
require(
    'packages/catalog/lib/src/cached_comic_source.dart',
    'CanonicalComicIdentitySource',
    'canonicalComicIdentity(String comicId)',
)
require(
    'packages/plugin_host/lib/src/runtime_source_adapter.dart',
    'canonicalMihonComicIdentity',
    '_canonicalWebIdentity',
    'CanonicalComicIdentitySource',
)
require(
    'apps/app/lib/demo_home.dart',
    "part 'demo_home_catalog_identity.dart';",
    'collapseCanonicalLibraryComics',
)
require(
    'apps/app/lib/demo_home_catalog_identity.dart',
    '_preferredSavedComicAlias',
    'collapsed-to-single-chapter',
    '_canonicalComicKey',
    'identityHash: _comicIdentityTraceHash',
)
require(
    'apps/app/lib/demo_home_details.dart',
    'requestedComicIdLength',
    'identityHash: _comicIdentityTraceHash',
)
forbid('apps/app/lib/demo_home.dart', 'List<LibraryComic> _collapseComicAliases')
require(
    'apps/app/lib/demo_home_source_compat.dart',
    'comic-identity-alias-resolved',
    'sameComicIdentity:',
    '_canonicalComicKey(source.sourceId, left)',
)
require(
    'apps/app/lib/comic_details.dart',
    'typedef ComicDetailsIdentityMatcher',
    'widget.sameComicIdentity',
    'final identities = <String>{widget.summary.comicId}',
    'comicId: chapter.comicId',
)
require(
    'apps/app/lib/comic_details.dart',
    'this.sameComicIdentity = _exactComicIdentity,',
    'final ComicDetailsIdentityMatcher sameComicIdentity;',
)
require(
    'apps/app/lib/demo_home_source_compat.dart',
    'sameComicIdentity: resolveCanonicalAlias',
    '_canonicalComicKey(source.sourceId, left)',
)
require(
    'packages/plugin_host/test/runtime_source_adapter_test.dart',
    'canonicalizes mutable Mihon manga aliases by source URL',
)
require(
    'packages/catalog/test/library_comic_test.dart',
    'canonical alias projection keeps the richer source catalog',
)
require(
    'packages/catalog/test/cached_comic_source_test.dart',
    'cached source preserves canonical comic identity capability',
)
require('tool/check.sh', 'test_dev90_mihon_runtime_identity_alias.py')

print('dev.90 Mihon runtime snapshot and canonical alias ownership: OK')
