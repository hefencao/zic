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


driver = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt')
registry = read('packages/plugin_host/lib/src/runtime_registry.dart')
controller = read('packages/plugin_host_bridge/lib/src/external_plugin_controller.dart')
details = read('apps/app/lib/comic_details.dart')
plugin_tests = read('packages/plugin_host/test/plugin_gate_test.dart')
check = read('tool/check.sh')

# Current Mihon/TachiyomiX host contract: getMangaUpdate/getPageList first;
# legacy Observable APIs only on explicit capability absence.
for token in (
    'val combined = try',
    'listOf(manga, existingChapters, true, true)',
    'if (!error.isMihonCapabilityAbsence())',
    'source.invokeMihonCompatible("fetchChapterList", listOf(manga))',
    'source.invokeMihonCompatible("getPageList", listOf(chapter))',
    'source.invokeMihonCompatible("fetchPageList", listOf(chapter))',
    'val existingChapters = cachedMihonChaptersForComic(source, comicId)',
    'private fun mihonSourceCacheKey(source: Any): String',
    'private fun mihonChapterCacheKey(source: Any, chapterId: String): String',
    'chapterById[mihonChapterCacheKey(source, chapterId)]',
    'Chapter objects are source-owned inputs to getPageList(SChapter)',
):
    require(driver, token, 'Mihon source contract')
if driver.index('val combined = try') >= driver.index('source.invokeMihonCompatible("fetchChapterList"'):
    raise SystemExit('legacy fetchChapterList runs before current getMangaUpdate')
if driver.index('source.invokeMihonCompatible("getPageList"') >= driver.index('source.invokeMihonCompatible("fetchPageList"'):
    raise SystemExit('legacy fetchPageList runs before current getPageList')
for token in (
    'source.invokeMihonCompatible("getChapterList"',
    'fetchMangaUpdate',
    'normalizeMihonChapterCatalog',
    'mihonChapterMetadataScore',
    'createSyntheticMihonChapter',
    'deduplicateMihonStartReadingEntries',
):
    forbid(driver, token, 'host chapter guessing')

# Preserve the complete HttpSource imageRequest(page), including request method,
# source headers/body and current OkHttp cookie/browser-UA session. Image bytes
# remain on host transport unless a source-owned runtime transform is required.
for token in (
    'source.invokeHierarchyCompatible("imageRequest", listOf(page))',
    'private fun mihonRequestResource(loader: ClassLoader, request: Any): JSONObject',
    '.put("method", method)',
    '.put("headers", JSONObject(headers))',
    'put("bodyBase64", Base64.encodeToString(body, Base64.NO_WRAP))',
    'private fun mihonRequestFromResource(source: Any, resource: JSONObject): Any',
    'cookieJar.invokeCompatible("loadForRequest", listOf(requestUrl))',
    'cookieJar.invokeCompatible("browserSessionUserAgent", listOf(requestUrl))',
    '"requiresRuntimeTransform" to (mihonTransportRevision(sourceId, source) != null)',
):
    require(driver, token, 'Mihon image request plan')
require(driver, 'if (method == "GET" || method == "HEAD") {\n            null', 'GET/HEAD zero-body plan')

# Plugin replacement is transactional: candidate must validate before old
# runtime/session disappears; controller install/update may not deactivate first.
for token in (
    'Future<List<BrowsableComicSource>> replace(',
    'final candidate = _activateCandidate(',
    'final committed = _enqueueCommit<List<BrowsableComicSource>>(() {',
    'if (!identical(_sessions[plugin.pluginId], existing))',
    '_installSession(plugin.pluginId, replacement);',
    'await existing.close();',
):
    require(registry, token, 'runtime replacement transaction')
for token in (
    'await _registry.replace(record.plugin)',
    'await _registry.replace(record.plugin);',
    'final replacingActive = _registry.isActive(pluginId);',
):
    require(controller, token, 'controller replacement path')
approve = controller[controller.index('Future<List<BrowsableComicSource>> approveAndActivate'):controller.index('Future<void> remove(', controller.index('Future<List<BrowsableComicSource>> approveAndActivate'))]
forbid(approve, '_registry.deactivate(', 'deactivate-before-install')


# dev.159 transaction remains the payload/code replacement owner. Runtime
# settings and Venera browser-login mutation are in-place capabilities and must
# not be forced through this replacement transaction.
settings = read('apps/app/lib/source_browser.dart') + read('apps/app/lib/external_source_settings_screen.dart')
source_compat = read('apps/app/lib/demo_home_source_compat.dart')
forbid(settings, '应用并重启', 'settings restart UI')
forbid(source_compat, 'restartSource(', 'generic browser/runtime restart')

# A valid empty chapter catalog is not a Cloudflare signal; only typed lower
# layer failures may open the verification recovery flow.
forbid(details, '漫画源未返回可确认的章节目录；这不代表单章节漫画', 'UI-invented chapter verification failure')

for token in (
    "runtime registry replaces only after candidate validation",
    "runtime registry keeps old session when replacement activation fails",
):
    require(plugin_tests, token, 'registry owner tests')
require(check, 'test_dev159_mihon_host_contract_resource_session_replacement.py', 'check integration')
print('dev.159 Mihon host/request/runtime replacement contract: OK')
