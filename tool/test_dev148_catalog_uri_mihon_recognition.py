#!/usr/bin/env python3
from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f'{owner} missing dev.148 contract: {token}')


def forbid(text: str, token: str, owner: str) -> None:
    if token in text:
        raise SystemExit(f'{owner} retains obsolete dev.148 path: {token}')


catalog = read('packages/catalog/lib/src/cached_comic_source.dart')
source_contract = read('packages/catalog/lib/src/source_catalog.dart')
mihon = read(
    'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/'
    'MihonRuntimeDriver.kt'
)
metadata = read(
    'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/'
    'PluginHostBridgePlugin.kt'
)
controller = read('packages/plugin_host_bridge/lib/src/external_plugin_controller.dart')
repository_screen = read('apps/app/lib/external_plugin_repository_screen.dart')
cookie_jar = read(
    'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/'
    'AndroidCookieJar.kt'
)
check = read('tool/check.sh')

require(source_contract, 'Uri? resolveComicWebUri(String comicId);', 'comic web URI interface')
require(catalog, 'Uri? resolveComicWebUri(String comicId)', 'cached nullable URI forwarding')
forbid(catalog, 'Uri resolveComicWebUri(String comicId)', 'non-null cached URI mismatch')

require(cookie_jar, 'fun resetBrowserSnapshotImports()', 'stable cookie reset boundary')
require(mihon, 'import dev.zic.network.AndroidCookieJar', 'Mihon stable network import')
require(mihon, 'AndroidCookieJar.resetBrowserSnapshotImports()', 'Mihon cookie reset call')
forbid(mihon, 'import dev.zic.network.AndroidBrowserCookieSession', 'internal cookie session import')
common_match = re.search(
    r'internal val requiredMihonCommonRuntimeClasses:.*?\n\)',
    mihon,
    re.S,
)
if common_match is None:
    raise SystemExit('Mihon common runtime class list is missing')
forbid(
    common_match.group(0),
    'dev.zic.network.AndroidBrowserCookieSession',
    'internal cookie class ABI requirement',
)
require(
    common_match.group(0),
    'dev.zic.network.AndroidCookieJar',
    'stable cookie jar ABI requirement',
)

for token in (
    'private fun metadataText(',
    'getResourcesForApplication(applicationInfo)',
    '.getString(raw)',
    'internal fun parseMihonEntryClasses(',
    '.split(Regex("""[;,\\r\\n]+"""))',
    'return hasFeature || hasKnownPackagePrefix',
):
    require(metadata, token, 'Mihon APK recognition')

kotlinc = shutil.which('kotlinc')
java = shutil.which('java')
if kotlinc and java:
    match = re.search(
        r'internal fun parseMihonEntryClasses\(.*?\n\}\n\nprivate val MIHON_ENTRY_CLASS_NAME = Regex\(.*?\n\)',
        metadata,
        re.S,
    )
    if match is None:
        raise SystemExit('Mihon entry metadata parser helper is missing')
    with tempfile.TemporaryDirectory() as raw_temp:
        temp = Path(raw_temp)
        source = temp / 'MihonMetadataSmoke.kt'
        source.write_text(
            'package dev.zic.pluginhost\n\n'
            + match.group(0)
            + '''

fun main() {
    check(
        parseMihonEntryClasses(
            "eu.kanade.tachiyomi.extension.zh.fixture",
            ".FirstFactory, .SecondFactory; .FirstFactory",
        ) == listOf(
            "eu.kanade.tachiyomi.extension.zh.fixture.FirstFactory",
            "eu.kanade.tachiyomi.extension.zh.fixture.SecondFactory",
        )
    )
    check(
        parseMihonEntryClasses(
            "eu.kanade.tachiyomi.extension.zh.fixture",
            "a.b.Factory\\nc.d.Factory",
        ) == listOf("a.b.Factory", "c.d.Factory")
    )
    check(
        runCatching {
            parseMihonEntryClasses(
                "eu.kanade.tachiyomi.extension.zh.fixture",
                "not a class",
            )
        }.isFailure
    )
    println("Mihon metadata recognition helper: OK")
}
''',
            encoding='utf-8',
        )
        jar = temp / 'mihon-metadata.jar'
        subprocess.run(
            [kotlinc, str(source), '-include-runtime', '-d', str(jar)],
            check=True,
        )
        subprocess.run([java, '-jar', str(jar)], check=True)
else:
    print('SKIP: kotlinc/java unavailable for Mihon metadata helper execution')


for token in (
    'Object? _deviceMihonDiscoveryError;',
    'Object? get deviceMihonDiscoveryError',
    '_deviceMihonDiscoveryError = error;',
    '_deviceMihonDiscoveryError = null;',
):
    require(controller, token, 'Mihon discovery diagnostics')
for token in (
    '_deviceError = widget.controller.deviceMihonDiscoveryError;',
    'void initState()',
):
    require(repository_screen, token, 'Mihon discovery error presentation')

require(check, 'test_dev148_catalog_uri_mihon_recognition.py', 'repository check')
print('dev.148 catalog URI / Mihon recognition contract: OK')
