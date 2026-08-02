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
        'allowSynthetic = !catalog.chapterCatalogAvailable',
        'var chapterCatalogAvailable = update != null',
        'Mihon source exposed neither a chapter catalog nor readable gallery pages',
    )
    if driver.index('catalog.chapterFailure?.let { throw it }') > driver.index(
        'allowSynthetic = !catalog.chapterCatalogAvailable',
    ):
        raise SystemExit('Mihon catalog failure must escape before synthetic selection')

    cloudflare = require(
        'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCloudflareInterceptor.kt',
        'setOf("cloudflare", "cloudflare-nginx")',
        'Cloudflare verification failed',
        'response.close()',
    )
    for forbidden in ('WebView(', 'CLOUDFLARE_WAIT_SECONDS', 'clearClearanceCookie'):
        if forbidden in cloudflare:
            raise SystemExit('Cloudflare runtime interceptor must return typed recovery to visible UI')
    for abi in ('mihonRuntime14', 'mihonRuntime16'):
        require(
            f'packages/plugin_host_bridge/android/src/{abi}/kotlin/eu/kanade/tachiyomi/network/RuntimeNetwork.kt',
            '.cookieJar(AndroidCookieJar(context))',
            'AndroidCloudflareInterceptor(context, ::defaultUserAgentProvider)',
            '.callTimeout(45, TimeUnit.SECONDS)',
        )

    details = require(
        'apps/app/lib/comic_details.dart',
        "ValueKey<String>('comic-details-open-webview')",
        '漫画源未返回可确认的章节目录；这不代表单章节漫画。',
        'onOpenSourceWebView',
    )
    if details.index('if (manifest.chapters.isEmpty)') > details.index(
        '_manifest = manifest',
    ):
        raise SystemExit('empty catalog must fail before becoming presentation state')
    forbid('apps/app/lib/comic_details.dart', 'isSyntheticMihonChapterIdentity')
    require(
        'apps/app/lib/demo_home.dart',
        'reconcileComicDetailsChapterEntries',
        'isCompatibilityFallback: isSyntheticMihonChapterIdentity',
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
        'localMediaBridgeProtocolVersion = 4',
        'localMediaBridgeChunkBytes = 256 * 1024',
        "'openDocument'",
        "'readDocumentChunk'",
        "'closeDocument'",
        'required this.partial',
    )
    if "invokeMethod<Uint8List>(\n      'readDocument'" not in bridge:
        raise SystemExit('legacy complete read must remain only as an explicit compatibility API')
    require(
        'packages/local_media_bridge/android/src/main/kotlin/dev/zic/localmedia/LocalMediaBridgePlugin.kt',
        'DOCUMENT_CHUNK_BYTES = 256 * 1024',
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
        'readChunks({int chunkSize = 256 * 1024})',
    )
    require(
        'packages/sessions/lib/src/source_progress.dart',
        '64 * 1024',
    )

    print('dev.85 Cloudflare/catalog/local-stream ownership contract: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
