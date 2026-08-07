#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        raise SystemExit(f'missing dev.85 contract file: {relative}')
    return path.read_text()


def require(relative: str, *tokens: str) -> str:
    value = text(relative)
    for token in tokens:
        if token not in value:
            raise SystemExit(f'{relative} is missing dev.85 contract: {token}')
    return value


def forbid(relative: str, *tokens: str) -> None:
    value = text(relative)
    for token in tokens:
        if token in value:
            raise SystemExit(f'{relative} violates dev.85 ownership: {token}')


def main() -> int:
    driver = require(
        'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt',
        'catalog.chapterFailure?.let { throw it }',
        'Invocation("getMangaUpdate", listOf(manga, existingChapters, true, true))',
        'normalizeMihonChapterCatalog(chapters)',
        'for (candidate in listOf("getChapterList", "fetchChapterList"))',
        'Mihon source exposes no compatible chapter-catalog operation',
    )
    if driver.index('for (candidate in listOf("getChapterList", "fetchChapterList"))') >= driver.index('Invocation("getMangaUpdate"'):
        raise SystemExit('explicit Mihon chapter catalog must precede combined update fallback')
    for stale in ('createSyntheticMihonChapter', 'selectMihonChapters'):
        if stale in driver:
            raise SystemExit(f'Mihon chapter failure must not synthesize host chapters: {stale}')

    cloudflare = require(
        'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCloudflareInterceptor.kt',
        'setOf("cloudflare", "cloudflare-nginx")',
        'SourceVerificationRequiredException',
        'response.close()',
    )
    for forbidden in ('WebView(', 'CLOUDFLARE_WAIT_SECONDS', 'clearClearanceCookie'):
        if forbidden in cloudflare:
            raise SystemExit('Cloudflare runtime interceptor must return typed recovery to visible UI')
    for abi in ('mihonRuntime14', 'mihonRuntime16'):
        require(
            f'packages/plugin_host_bridge/android/src/{abi}/kotlin/eu/kanade/tachiyomi/network/RuntimeNetwork.kt',
            'private val cookieJar by lazy',
            '.cookieJar(cookieJar)',
            'AndroidCloudflareInterceptor(context, ::defaultUserAgentProvider) { url ->',
            '.callTimeout(45, TimeUnit.SECONDS)',
        )

    details = require(
        'apps/app/lib/comic_details.dart',
        "ValueKey<String>('comic-details-open-webview')",
        '漫画源未返回可确认的章节目录；这不代表单章节漫画。',
        'onOpenSourceWebView',
    )
    if details.index('if (sourceChapters.isEmpty)') > details.index(
        '_manifest = manifest',
    ):
        raise SystemExit('empty catalog must fail before becoming presentation state')
    if 'widget.source.loadComic(widget.summary.comicId)' in details:
        raise SystemExit('remote details must consume the composition refresh result')
    forbid('apps/app/lib/comic_details.dart', 'isSyntheticMihonChapterIdentity')
    forbid('apps/app/lib/demo_home.dart', 'reconcileComicDetailsChapterEntries')
    forbid(
        'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt',
        'deduplicateMihonStartReadingEntries(',
        'createSyntheticMihonChapter',
    )
    require(
        'apps/app/lib/demo_home_source_compat.dart',
        'widget.networkBridge.openBrowser(',
    )

    require(
        'packages/transport/lib/src/transport.dart',
        'const int defaultTransportChunkBytes = 256 * 1024;',
    )
    require(
        'packages/transport/lib/src/io_transport.dart',
        'defaultTransportChunkBytes',
        'await file.open()',
    )
    bridge = require(
        'packages/local_media_bridge/lib/src/local_media_bridge.dart',
        'localMediaBridgeProtocolVersion = 5',
        'localMediaBridgeChunkBytes = 1024 * 1024',
        "'openDocument'",
        "'readDocumentChunk'",
        "'closeDocument'",
        'required this.partial',
    )
    if "invokeMethod<Uint8List>(\n      'readDocument'" not in bridge:
        raise SystemExit('legacy complete read must remain only as an explicit compatibility API')
    require(
        'packages/local_media_bridge/android/src/main/kotlin/dev/zic/localmedia/LocalMediaBridgePlugin.kt',
        'DOCUMENT_CHUNK_BYTES = 1024 * 1024',
        'documentHandles',
        '"partial" to canServeRange',
        'closeAllDocuments()',
    )
    require(
        'packages/local_media_ui/lib/src/local_media_screens.dart',
        "uri.scheme == 'content'",
        '_openLocalMediaResponse(',
        'final partial = response.partial;',
    )
    require(
        'packages/storage/lib/src/artifact.dart',
        'Stream<List<int>> readChunks({',
    )
    require(
        'packages/sessions/lib/src/source_progress.dart',
        '64 * 1024',
    )

    print('dev.85 Cloudflare/catalog/local-stream ownership contract: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
