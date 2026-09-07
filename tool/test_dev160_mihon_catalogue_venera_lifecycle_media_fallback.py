#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')


def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'forbidden {label}: {token}')


source16 = read('packages/plugin_host_bridge/android/src/mihonRuntime16/kotlin/eu/kanade/tachiyomi/source/Source.kt')
catalogue16 = read('packages/plugin_host_bridge/android/src/mihonRuntime16/kotlin/eu/kanade/tachiyomi/source/CatalogueSource.kt')
driver = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt')
settings = read('apps/app/lib/source_browser.dart') + read('apps/app/lib/external_source_settings_screen.dart')
source_compat = read('apps/app/lib/demo_home_source_compat.dart')
controller = read('packages/plugin_host_bridge/lib/src/external_plugin_controller.dart')
entrypoint = read('packages/plugin_host_bridge/lib/runtime_service_entrypoint.dart')
transport = read('packages/downloads/lib/src/source_resource_transport.dart')
content_sniffer = read('packages/transport/lib/src/content_sniffer.dart')
cache = read('packages/catalog/lib/src/cached_comic_source.dart')
check = read('tool/check.sh')

# Match the uploaded/current Mihon Source + CatalogueSource contract rather than
# bypassing it with ZIC-owned ABI guesses. Both detail and chapter requests use
# the original SManga input.
for token in (
    'val lang: String',
    'suspend fun getMangaUpdate(',
    'fun fetchChapterList(manga: SManga)',
):
    require(source16, token, 'Mihon 1.6 Source contract')
for token in (
    'override val lang: String',
    'fetchMangaDetails(manga).awaitSingleCompat()',
    'fetchChapterList(manga).awaitSingleCompat()',
):
    require(catalogue16, token, 'Mihon CatalogueSource compatibility')
for token in ('import kotlinx.coroutines', 'supervisorScope', 'async {'):
    forbid(catalogue16, token, 'ABI-generator coroutine dependency')
forbid(catalogue16, 'fetchChapterList(updatedManga)', 'mutated chapter request identity')
forbid(catalogue16, 'fetchChapterList(detailedManga)', 'mutated chapter request identity')
require(driver, 'source.invokeMihonCompatible("fetchChapterList", listOf(manga))', 'legacy chapter request identity')
forbid(driver, 'source.invokeMihonCompatible("fetchChapterList", listOf(detailedManga))', 'legacy detailed-manga chapter identity')

# Settings/login are runtime capabilities, not code/payload lifecycle events.
forbid(settings, '应用并重启', 'settings restart UX')
forbid(settings, '.restartSource(', 'settings runtime replacement')
require(source_compat, 'accountSource.confirmWebLogin(', 'in-place Venera login confirmation')
require(source_compat, "if (source.sourceId.startsWith('mihon:'))", 'Mihon-only browser lifecycle exception')
require(source_compat, 'restartMihonSourceForBrowserHandoff', 'Mihon browser handoff')
forbid(source_compat, 'restartSource(', 'generic browser runtime restart')
require(controller, 'Future<void> restartMihonSourceForBrowserHandoff(String sourceId)', 'Mihon-only restart API')
require(controller, "record.plugin.format != ExternalComicPluginFormat.mihonExtension", 'Mihon-only owner validation')
forbid(controller, 'Future<void> restartSource(String sourceId)', 'generic restart API')

# Production capacity is a safety ceiling, not an eight-plugin user limit.
for token in (
    'const int _productionExternalPluginSessionLimit = 32;',
    'maxActiveSessions: _productionExternalPluginSessionLimit',
):
    require(entrypoint, token, 'production plugin session capacity')

# Shared direct media transport must not impersonate Venera for Mihon. A 2xx
# non-media response is rejected before Pipeline and handed to the existing
# source-owned compatibility path.
forbid(transport, "_client.userAgent = 'zic-venera/0.31.0'", 'cross-source default user agent')
for token in (
    "error.details['sourceMediaProtocolMismatch'] == true",
    '_openRuntimeFallback(',
    'await _prefetchEncodedMediaBody(',
    "'sourceMediaProtocolMismatch': true",
    'hasSupportedEncodedImageSignature',
):
    require(transport, token, 'source-owned media compatibility fallback')
require(
    content_sniffer,
    'bool hasSupportedEncodedImageSignature(List<int> prefix)',
    'shared encoded-image signature authority',
)

# Previously cached bad Mihon manifests must not mask the corrected catalog
# contract after upgrade; do not invalidate unrelated source ecosystems.
for token in (
    "'chapter-metadata-v3-source-contract-refresh'",
    "identity.sourceId.startsWith('mihon:')",
    "'mihon-comic-details-v2-host-contract'",
):
    require(cache, token, 'Mihon catalog cache revision')

require(check, 'test_dev160_mihon_catalogue_venera_lifecycle_media_fallback.py', 'check integration')
print('dev.160 Mihon catalogue / Venera lifecycle / media fallback contract: OK')
