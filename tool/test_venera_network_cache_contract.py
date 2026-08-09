#!/usr/bin/env python3
"""Compile and execute the source-requested Venera Network cache helpers."""
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt'


def main() -> int:
    source = SOURCE.read_text(encoding='utf-8')
    required = (
        'val cacheTime = rawHeaders.veneraControlHeader("cache-time")',
        'name.lowercase(Locale.US) !in VENERA_NETWORK_CONTROL_HEADERS',
        'private val networkCache = VeneraHttpCache()',
        'networkCache.lookup(',
        'networkCache.store(cacheUrl, headers, result)',
        'cacheHeaders.put("venera-cache", "true")',
        'sourcePlanBridgeNetworkCacheHits',
        'sourcePlanBridgeNetworkOriginCalls',
    )
    for token in required:
        if token not in source:
            raise SystemExit(f'Venera Network cache contract missing: {token}')

    kotlinc = shutil.which('kotlinc')
    java = shutil.which('java')
    if not kotlinc or not java:
        print('SKIP: kotlinc/java are not installed for Venera cache helper execution')
        return 0

    response = re.search(
        r'private data class VeneraHttpResponse\(.*?\n\}\n',
        source,
        re.S,
    )
    helper = re.search(
        r'private data class VeneraHttpCacheEntry\(.*?\n(?=private fun MutableMap<String, String>\.removeVeneraHeader)',
        source,
        re.S,
    )
    if response is None or helper is None:
        raise SystemExit('Venera cache helper block not found')
    constants = re.search(
        r'private const val VENERA_NETWORK_MAX_CACHE_BYTES = .*?\nprivate val VENERA_CACHE_IGNORED_HEADERS = setOf\(.*?\n\)\n',
        source,
        re.S,
    )
    if constants is None:
        raise SystemExit('Venera cache constants not found')

    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        (work / 'JSONObject.kt').write_text(
            '''package org.json
class JSONObject(raw: String? = null) {
    private val values = linkedMapOf<String, Any?>()
    fun put(name: String, value: Any?): JSONObject { values[name] = value; return this }
    override fun toString(): String = values.toString()
}
''', encoding='utf-8')
        (work / 'Smoke.kt').write_text(
            '''package dev.zic.pluginhost
import java.util.Locale
import org.json.JSONObject
private fun encodeWireValue(value: Any?): Any? = value
'''
            + response.group(0)
            + '\n'
            + helper.group(0)
            + '\n'
            + constants.group(0)
            + '''
fun main() {
    val cache = VeneraHttpCache()
    val headers = linkedMapOf("Cookie" to "nw=1; session=a", "Accept-Encoding" to "gzip")
    val response = VeneraHttpResponse(200, JSONObject().put("content-type", "text/html"), "cached".encodeToByteArray())
    cache.store("https://fixture/gallery", headers, response, nowNanos = 1_000L)
    check(cache.lookup("https://fixture/gallery", headers, "long", nowNanos = 1_000L + 60L * 60L * 1_000_000_000L) != null)
    check(cache.lookup("https://fixture/gallery", headers + ("Cookie" to "nw=1; session=b"), "long", nowNanos = 2_000L) == null)
    check(veneraCacheHeadersMatch(mapOf("Authorization" to "a", "Cookie" to "c"), mapOf("Authorization" to "b", "Cookie" to "c")))
    check(!veneraCacheHeadersMatch(mapOf("Cookie" to "a"), mapOf("Cookie" to "b")))
    cache.store("https://fixture/short", headers, response, nowNanos = 10_000L)
    check(cache.lookup("https://fixture/short", headers, null, nowNanos = 10_000L + 4L * 1_000_000_000L) != null)
    check(cache.lookup("https://fixture/short", headers, null, nowNanos = 10_000L + 6L * 1_000_000_000L) == null)
    cache.store("https://fixture/no", headers, response, nowNanos = 20_000L)
    check(cache.lookup("https://fixture/no", headers, "no", nowNanos = 21_000L) == null)
    check(cache.lookup("https://fixture/no", headers, "long", nowNanos = 22_000L) == null)
    println("Venera source-requested network cache: OK")
}
''', encoding='utf-8')
        jar = work / 'cache.jar'
        subprocess.run([
            kotlinc, str(work / 'JSONObject.kt'), str(work / 'Smoke.kt'),
            '-include-runtime', '-d', str(jar),
        ], check=True)
        subprocess.run([java, '-jar', str(jar)], check=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
