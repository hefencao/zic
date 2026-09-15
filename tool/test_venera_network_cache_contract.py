#!/usr/bin/env python3
"""Compile and execute the source-requested Venera Network cache helpers."""
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt'
CACHE_SOURCE = ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraHttpCacheStore.kt'


def main() -> int:
    source = SOURCE.read_text(encoding='utf-8')
    cache_source = CACHE_SOURCE.read_text(encoding='utf-8')
    runtime_required = (
        'val cacheTime = rawHeaders.veneraControlHeader("cache-time")',
        'name.lowercase(Locale.US) !in VENERA_NETWORK_CONTROL_HEADERS',
        'private val networkCache: VeneraHttpCacheStore',
        'private val networkCacheNamespace: VeneraHttpCacheNamespace',
        'networkCache.lookup(',
        'networkCache.store(',
        'namespace = networkCacheNamespace',
        'sourcePlanBridgeNetworkCacheHits',
        'sourcePlanBridgeNetworkOriginCalls',
    )
    for token in runtime_required:
        if token not in source:
            raise SystemExit(f'Venera Network cache contract missing: {token}')
    for token in (
        'internal class VeneraHttpCacheStore(',
        'internal data class VeneraHttpCacheNamespace(',
        'cacheHeaders.put("venera-cache", "true")',
        'VENERA_NETWORK_MAX_CACHE_BYTES = 10 * 1024 * 1024',
        'VENERA_NETWORK_LONG_CACHE_NANOS = 6L * 60L * 60L * 1_000_000_000L',
    ):
        if token not in cache_source:
            raise SystemExit(f'Venera Network cache implementation missing: {token}')

    kotlinc = shutil.which('kotlinc')
    java = shutil.which('java')
    if not kotlinc or not java:
        print('SKIP: kotlinc/java are not installed for Venera cache helper execution')
        return 0

    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        (work / 'JSONObject.kt').write_text(
            '''package org.json
class JSONObject(raw: String? = null) {
    private val values = linkedMapOf<String, Any?>()
    fun put(name: String, value: Any?): JSONObject { values[name] = value; return this }
    fun keys(): Iterator<String> = values.keys.iterator()
    fun optString(name: String): String = values[name]?.toString() ?: ""
    override fun toString(): String = values.toString()
}
''', encoding='utf-8')
        (work / 'Log.kt').write_text(
            '''package android.util
object Log {
    const val DEBUG: Int = 3
    fun isLoggable(tag: String, level: Int): Boolean = false
    fun d(tag: String, message: String): Int = 0
}
''', encoding='utf-8')
        (work / 'VeneraHttpCacheStore.kt').write_text(cache_source, encoding='utf-8')
        (work / 'Smoke.kt').write_text(
            '''package dev.zic.pluginhost
import org.json.JSONObject
internal data class VeneraHttpResponse(
    val status: Int,
    val headers: JSONObject,
    val body: ByteArray,
)
fun main() {
    val cache = VeneraHttpCacheStore()
    val headers = linkedMapOf("Cookie" to "nw=1; session=a", "Accept-Encoding" to "gzip")
    val response = VeneraHttpResponse(200, JSONObject().put("content-type", "text/html"), "cached".encodeToByteArray())
    cache.store(VeneraHttpCacheNamespace("plugin", "v1", "source-a"), "https://fixture/gallery", headers, response, nowNanos = 1_000L)
    check(cache.lookup(VeneraHttpCacheNamespace("plugin", "v1", "source-a"), "https://fixture/gallery", headers, "long", nowNanos = 1_000L + 60L * 60L * 1_000_000_000L) != null)
    check(cache.lookup(VeneraHttpCacheNamespace("plugin", "v1", "source-a"), "https://fixture/gallery", headers + ("Cookie" to "nw=1; session=b"), "long", nowNanos = 2_000L) == null)
    check(cache.lookup(VeneraHttpCacheNamespace("plugin", "v1", "source-b"), "https://fixture/gallery", headers, "long", nowNanos = 2_000L) == null)
    check(cache.lookup(VeneraHttpCacheNamespace("plugin", "v2", "source-a"), "https://fixture/gallery", headers, "long", nowNanos = 2_000L) == null)
    check(veneraCacheHeadersMatch(mapOf("Authorization" to "a", "Cookie" to "c"), mapOf("Authorization" to "b", "Cookie" to "c")))
    check(!veneraCacheHeadersMatch(mapOf("Cookie" to "a"), mapOf("Cookie" to "b")))
    cache.store(VeneraHttpCacheNamespace("plugin", "v1", "source-a"), "https://fixture/short", headers, response, nowNanos = 10_000L)
    check(cache.lookup(VeneraHttpCacheNamespace("plugin", "v1", "source-a"), "https://fixture/short", headers, null, nowNanos = 10_000L + 4L * 1_000_000_000L) != null)
    check(cache.lookup(VeneraHttpCacheNamespace("plugin", "v1", "source-a"), "https://fixture/short", headers, null, nowNanos = 10_000L + 6L * 1_000_000_000L) == null)
    cache.store(VeneraHttpCacheNamespace("plugin", "v1", "source-a"), "https://fixture/no", headers, response, nowNanos = 20_000L)
    check(cache.lookup(VeneraHttpCacheNamespace("plugin", "v1", "source-a"), "https://fixture/no", headers, "no", nowNanos = 21_000L) == null)
    check(cache.lookup(VeneraHttpCacheNamespace("plugin", "v1", "source-a"), "https://fixture/no", headers, "long", nowNanos = 22_000L) == null)
    println("Venera shared source-requested network cache: OK")
}
''', encoding='utf-8')
        jar = work / 'cache.jar'
        subprocess.run([
            kotlinc,
            str(work / 'JSONObject.kt'),
            str(work / 'Log.kt'),
            str(work / 'VeneraHttpCacheStore.kt'),
            str(work / 'Smoke.kt'),
            '-include-runtime', '-d', str(jar),
        ], check=True)
        subprocess.run([java, '-jar', str(jar)], check=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
