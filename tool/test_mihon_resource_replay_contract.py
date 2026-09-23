#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


driver = read(
    'packages/plugin_host_bridge/android/src/main/kotlin/'
    'dev/zic/pluginhost/MihonRuntimeDriver.kt'
)
adapter = read('packages/plugin_host/lib/src/runtime_source_adapter.dart')
transport = read('packages/downloads/lib/src/source_resource_transport.dart')
compat = read('apps/app/lib/demo_home_source_compat.dart')
reader_composition = read('apps/app/lib/home_reader_composition.dart')
download_commands = read('apps/app/lib/home_download_commands.dart')
reader_route = read('apps/app/lib/demo_home_reader_route.dart')
whole_comic = read('packages/downloads/lib/src/whole_comic_downloads.dart')
check = read('tool/check.sh')

for token in (
    'MIHON_RUNTIME_TRANSFORM_REVISION = "mihon-runtime-transform-v2"',
    '"retryResource" -> retryResource(',
    '.put("retryChapterId", retryChapterId)',
    '.put("retryPageIndex", index)',
    'val chapter = resolveMihonChapter(source, chapterId, encodedChapter, requestId)',
    'val pages = loadMihonPageModels(source, chapter, requestId)',
    '"request" to requestPlan',
    '"retryResource",',
    'mihonResourceReplayKey(sourceId, replayUri)',
    '!replayEligibleResourceUris.remove(replayKey)',
    'freshGeneration = arguments["freshGeneration"] == true',
    'freshResourcePlans[mihonResourceReplayKey(sourceId, uri)]',
    'rememberFreshResourcePlan(replayKey, requestPlan)',
    'private fun invalidateMihonResourcePlans(sourceId: String)',
    'invalidateMihonResourcePlans(sourceId)',
    'put("sourceResourcePlanReplayEligible", true)',
):
    if token not in driver:
        raise SystemExit(f'Mihon durable resource replay contract missing: {token}')

if driver.index('"retryResource" -> retryResource(') > driver.index(
    'else -> error("unsupported Mihon runtime operation")'
):
    raise SystemExit('Mihon retryResource is outside runtime dispatch')

for token in (
    'ExternalPluginRuntimeOperation.retryResource,',
    "'freshGeneration': true",
    "'available'",
    "'request'",
):
    if token not in adapter:
        raise SystemExit(f'Mihon adapter retry contract missing: {token}')

legacy_shortcut = '''if (_format == ExternalComicPluginFormat.mihonExtension) {
      // A failed host-side stream can mean that a deferred Mihon page URL'''
if legacy_shortcut in adapter:
    raise SystemExit('Mihon retry still aliases retryResource to stale resolveResource')

for token in (
    "_isSourceResourcePlanReplayEligible(error)",
    "_sourceResourcePlanReplayUnavailableFailure(",
    "bool sourceResourceGenerationRefreshEligible(Object error)",
    "'sourceResourcePlanReplayAttempted': true",
    "'sourceResourcePlanReplayUnavailable': true",
):
    if token not in transport:
        raise SystemExit(f'source-plan replay transport contract missing: {token}')

for token in (
    'bool _hasLegacyMihonRuntimeTransformLocators(ImportedChapterRecord chapter)',
    "chapter.sourceId.startsWith('mihon:')",
    "chapter.sourceRevision.endsWith(':mihon-runtime-transform-v1')",
    '_manifestRequiresSourceLocatorRefresh(manifest)',
):
    if token not in compat:
        raise SystemExit(f'Mihon v1 locator migration contract missing: {token}')

reader_refresh = '''sourceLocatorRefreshRequired
        ? await _refreshRemoteEntry(entry, forceSourceRefresh: true)'''
if reader_refresh not in reader_composition:
    raise SystemExit('Reader composition does not force-refresh legacy locators')

if download_commands.count('forceSourceRefresh: true') < 2:
    raise SystemExit('download commands do not force-refresh legacy locators')

for owner, source in (
    ('Reader', reader_route),
    ('chapter download commands', download_commands),
    ('whole-comic queue', whole_comic),
):
    if 'sourceResourceGenerationRefreshEligible(error)' not in source:
        raise SystemExit(f'{owner} does not consume terminal source-generation handoff')

if 'test_mihon_resource_replay_contract.py' not in check:
    raise SystemExit('Mihon resource replay contract is not wired into tool/check.sh')

print('Mihon durable resource replay contract: OK')
