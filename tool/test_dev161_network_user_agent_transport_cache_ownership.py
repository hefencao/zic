#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.161 tokens: {missing}')


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains superseded network tokens: {found}')

require(
    'apps/app/lib/app_preferences.dart',
    'const defaultNetworkUserAgent =',
    'Chrome/150.0.0.0 Mobile Safari/537.36',
    'String get networkUserAgent => _networkUserAgent;',
    "'networkUserAgent': _networkUserAgent",
)
preferences = read('apps/app/lib/app_preferences.dart')
version_match = re.search(r"'version':\s*(\d+)", preferences)
if version_match is None or int(version_match.group(1)) < 6:
    raise SystemExit('FAIL: app preference schema must preserve dev.161 network UA persistence')
require(
    'apps/app/lib/app_settings_screen.dart',
    "ValueKey<String>('network-user-agent')",
    "ValueKey<String>('network-user-agent-apply')",
    '恢复 Chrome 默认值',
)
require(
    'apps/app/lib/app_runtime.dart',
    'userAgentProvider: () => preferences.networkUserAgent',
)
require(
    'apps/app/lib/demo_home.dart',
    'userAgentProvider: () => widget.preferences.networkUserAgent',
    'defaultUserAgentProvider: () => widget.preferences.networkUserAgent',
)
reader_route = read('apps/app/lib/demo_home_reader_route.dart')
for seam in (
    'observedPageControlledResponseLoaderFor',
    'pageOpenSelfBoundedFor',
):
    if re.search(r'_sourceResources\s*\.\s*' + seam + r'\s*\(', reader_route) is None:
        raise SystemExit(
            'FAIL: apps/app/lib/demo_home_reader_route.dart missing '
            f'dev.161 controlled source seam: {seam}',
        )
forbid('apps/app/lib/demo_home.dart', '_sourceResources.responseLoaderFor(')
forbid('apps/app/lib/demo_home_reader_route.dart', '_sourceResources.responseLoaderFor(')
require(
    'apps/app/lib/demo_home_source_compat.dart',
    'effectiveUserAgent = request.userAgent?.trim().isNotEmpty == true',
    'widget.preferences.networkUserAgent',
    'userAgent: effectiveUserAgent',
)

require(
    'packages/transport/lib/src/io_transport.dart',
    'String Function()? userAgentProvider',
    'request.headers.set(HttpHeaders.userAgentHeader, userAgent);',
)
require(
    'packages/downloads/lib/src/source_resource_transport.dart',
    "'sourceClientStateRequired': true",
    'if (response.isRedirect) {',
    'request.followRedirects = false;',
    'final response = await directOpen(effective);',
    '_applyDefaultUserAgent(',
    'String Function()? defaultUserAgentProvider',
    'if (_hasHeader(request.headers, HttpHeaders.userAgentHeader)) return request;',
)
require(
    'apps/app/lib/source_resource_gateway.dart',
    'defaultUserAgentProvider: defaultUserAgentProvider',
    'Future<Uint8List> loadPageBytes(',
    'ExternalPluginResourceResponseLoader pageResponseLoaderFor(',
    'pageControlledResponseLoaderFor(',
    'observedPageControlledResponseLoaderFor(',
    'final loader = pageControlledResponseLoaderFor(manifest.sourceId, page.uri);',
    'Raw page-body streaming escape hatch.',
    'loadCachedComicImageSource(',
)
forbid(
    'apps/app/lib/source_resource_gateway.dart',
    'Future<Uint8List> loadBytes(String sourceId, Uri uri)',
    'ExternalPluginResourceResponseLoader responseLoaderFor(',
)
require(
    'packages/catalog/lib/src/mangadex_source.dart',
    'String Function()? userAgentProvider',
    'userAgentProvider: userAgentProvider',
)
require(
    'packages/downloads/lib/src/chapter_downloads.dart',
    'String Function()? userAgentProvider',
    'HttpTransport(userAgentProvider: userAgentProvider)',
)
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'PipelineReaderSessionFactory withUserAgentProvider(',
    'HttpTransport(userAgentProvider: userAgentProvider)',
)
require(
    'packages/plugin_host_bridge/lib/src/external_plugin_controller.dart',
    'final String Function()? userAgentProvider;',
    'configuredUserAgent',
)
require(
    'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt',
    'mihonHostReplaySafeClientCapability',
    'capability.javaClass.classLoader === sourceLoader',
    'name == "dev.zic.network.AndroidCookieJar"',
    'name == "dev.zic.network.FallbackDns"',
)

require(
    'packages/plugin_host_bridge/android/src/mihonRuntime16/kotlin/eu/kanade/tachiyomi/source/CatalogueSource.kt',
    'override val lang: String',
    'fetchMangaDetails(manga).awaitSingleCompat()',
    'fetchChapterList(manga).awaitSingleCompat()',
)
forbid(
    'packages/plugin_host_bridge/android/src/mihonRuntime16/kotlin/eu/kanade/tachiyomi/source/CatalogueSource.kt',
    'import kotlinx.coroutines',
    'supervisorScope',
    'async {',
)

# Production presentation must not create independent HTTP clients.
for path in (ROOT / 'apps/app/lib').rglob('*.dart'):
    text = path.read_text(encoding='utf-8')
    if 'HttpClient(' in text or '.getUrl(' in text or '.openUrl(' in text:
        raise SystemExit(f'FAIL: App presentation owns direct HTTP: {path.relative_to(ROOT)}')

# The low-level source transport may only be consumed by the gateway in
# production. Tests exercise it directly as owner tests.
for path in ROOT.rglob('*.dart'):
    rel = path.relative_to(ROOT).as_posix()
    if '/test/' in f'/{rel}' or rel == 'packages/downloads/lib/src/source_resource_transport.dart':
        continue
    text = path.read_text(encoding='utf-8')
    if any(token in text for token in ('.loaderFor(', '.controlledLoaderFor(')) and rel != 'apps/app/lib/source_resource_gateway.dart':
        raise SystemExit(f'FAIL: raw source transport bypasses gateway: {rel}')


# Direct-network ownership is closed over an explicit set of infrastructure
# owners. New production HTTP construction must choose one of these owners
# instead of appearing in presentation or an arbitrary package.
allowed_direct_http_dart = {
    'packages/transport/lib/src/io_transport.dart',
    'packages/downloads/lib/src/source_resource_transport.dart',
    'packages/plugin_host_bridge/lib/src/external_plugin_controller.dart',
}
for path in ROOT.rglob('*.dart'):
    rel = path.relative_to(ROOT).as_posix()
    if '/test/' in f'/{rel}':
        continue
    text = path.read_text(encoding='utf-8')
    if any(token in text for token in ('HttpClient(', '.getUrl(', '.openUrl(')):
        if rel not in allowed_direct_http_dart:
            raise SystemExit(f'FAIL: unowned direct Dart HTTP: {rel}')

allowed_url_connection_kotlin = {
    'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/FallbackDns.kt',
    'packages/plugin_host_bridge/android/src/mihonRuntimeCommon/kotlin/dev/zic/mihonruntime/FallbackDns.kt',
    'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt',
}
for path in ROOT.rglob('*.kt'):
    rel = path.relative_to(ROOT).as_posix()
    if '/test/' in f'/{rel}':
        continue
    text = path.read_text(encoding='utf-8')
    if 'HttpURLConnection' in text or '.openConnection()' in text:
        if rel not in allowed_url_connection_kotlin:
            raise SystemExit(f'FAIL: unowned direct Kotlin URL connection: {rel}')

# The source-resource transport is a low-level owner, never an App service.
for path in ROOT.rglob('*.dart'):
    rel = path.relative_to(ROOT).as_posix()
    if '/test/' in f'/{rel}':
        continue
    text = path.read_text(encoding='utf-8')
    if 'ExternalPluginResourceTransportPool(' in text and rel not in {
        'apps/app/lib/source_resource_gateway.dart',
        'packages/downloads/lib/src/source_resource_transport.dart',
    }:
        raise SystemExit(f'FAIL: source transport pool bypasses gateway: {rel}')
    if '.loadResource(' in text and rel.startswith('apps/app/lib/') and rel != 'apps/app/lib/source_resource_gateway.dart':
        raise SystemExit(f'FAIL: App bypasses source resource gateway: {rel}')
    if any(token in text for token in ('.pageResponseLoaderFor(', '.pageControlledResponseLoaderFor(')) and rel not in {
        'apps/app/lib/source_resource_gateway.dart',
        'apps/app/lib/demo_home.dart',
        'apps/app/lib/demo_home_reader_route.dart',
    }:
        raise SystemExit(f'FAIL: page-body transport escaped Reader/download composition: {rel}')

print('dev.161 network UA / transport / cache ownership: OK')
