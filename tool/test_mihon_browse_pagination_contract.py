#!/usr/bin/env python3
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt'


def main() -> int:
    production = DRIVER.read_text()
    match = re.search(r'private fun browse\(.*?\n    \}', production, re.DOTALL)
    if match is None:
        raise SystemExit('Mihon browse implementation could not be extracted')
    kotlinc = shutil.which('kotlinc')
    java = shutil.which('java')
    if not kotlinc or not java:
        raise SystemExit('Mihon browse behavior is unverified: kotlinc/java missing')
    harness = r'''package dev.zic.pluginhost
private data class Manga(val id: Int)
private data class MangasPage(val mangas: List<Any>, val hasNextPage: Boolean)
private data class Invocation(val method: String, val args: List<Any?>)
private class Source(val sizes: List<Int>) {
    val calls = mutableListOf<Pair<String, Int>>()
}
private fun Any.invokeFirst(invocations: List<Invocation>): Any {
    val source = this as Source
    val call = invocations.first()
    val page = call.args.first() as Int
    source.calls += call.method to page
    val count = source.sizes.getOrElse(page - 1) { 0 }
    val start = source.sizes.take(page - 1).sum()
    return MangasPage((start until start + count).map { Manga(it) }, page < source.sizes.size)
}
private fun Any.invokeOptional(method: String): Any? = null
private fun emptyFilterList(loader: ClassLoader): Any = emptyList<Any>()
private fun Any?.unwrapAsync(): Any = requireNotNull(this)
private fun Any.asObjectList(): List<Any> = this as List<Any>
private fun Any.readList(vararg names: String): List<Any> = (this as MangasPage).mangas
private fun Any.readBoolean(vararg names: String): Boolean? =
    if (this is Source) true else (this as MangasPage).hasNextPage
private fun Map<String, Any?>.nonNegativeInt(name: String): Int = (getValue(name) as Int).also { require(it >= 0) }
private fun Map<String, Any?>.positiveInt(name: String): Int = (getValue(name) as Int).also { require(it > 0) }
private fun Any?.asStringAnyMap(name: String): Map<String, Any?> = emptyMap()
private object MihonFilterCodec {
    fun apply(filters: List<Any>, state: Map<String, Any?>, loader: ClassLoader) {}
}
private var cancellationChecks = 0
private fun ensureNotCancelled(requestId: String) {
    cancellationChecks++
    if (requestId == "cancelled") throw InterruptedException("cancelled")
}
private fun mangaSummary(source: Any, manga: Any): Map<String, Any?> = mapOf("id" to (manga as Manga).id)
''' + match.group(0) + r'''
private fun request(offset: Int, section: String, query: String = "", filters: Boolean = false) =
    mapOf<String, Any?>("offset" to offset, "limit" to 24, "sectionId" to section,
                      "query" to query, "useFilters" to filters)
private fun ids(result: Map<String, Any?>): List<Int> =
    (result.getValue("items") as List<Map<String, Any?>>).map { it.getValue("id") as Int }
fun main() {
    for ((section, query, filters, method) in listOf(
        listOf("popular", "", false, "getPopularManga"),
        listOf("latest", "", false, "getLatestUpdates"),
        listOf("popular", "query", false, "getSearchMangaList"),
        listOf("popular", "", true, "getSearchMangaList"),
    )) {
        val source = Source(listOf(20, 30, 7))
        val first = browse(source, request(0, section as String, query as String, filters as Boolean), "first")
        check(ids(first) == (0 until 20).toList()) { "native first page changed" }
        val next = first["nextOffset"] ?: ids(first).size
        check(next == 24) { "native20 next coordinate is $next instead of24" }
        val second = browse(source, request(next as Int, section, query, filters), "second")
        check(ids(second) == (20 until 50).toList()) { "native30 page was truncated or repeated" }
        check(second["nextOffset"] == 48)
        val last = browse(source, request(48, section, query, filters), "last")
        check(ids(last) == (50 until 57).toList())
        check(last["hasMore"] == false && last["nextOffset"] == null)
        val previous = browse(source, request(24, section, query, filters), "previous")
        check(ids(previous) == ids(second))
        check(source.calls == listOf(method to 1, method to 2, method to 3, method to 2))
    }
    val empty = Source(listOf(0, 5))
    val firstEmpty = browse(empty, request(0, "popular"), "empty")
    check(ids(firstEmpty).isEmpty() && firstEmpty["hasMore"] == true)
    check(firstEmpty["nextOffset"] == 24)
    check(ids(browse(empty, request(24, "popular"), "after-empty")) == (0 until 5).toList())
    check(runCatching { browse(Source(listOf(20)), request(20, "popular"), "unaligned") }
          .exceptionOrNull() is IllegalArgumentException)
    check(runCatching { browse(Source(listOf(20)), request(0, "popular"), "cancelled") }
          .exceptionOrNull() is InterruptedException)
    check(cancellationChecks > 0)
}
'''
    with tempfile.TemporaryDirectory(prefix='zic-mihon-browse-contract-') as directory:
        source = Path(directory) / 'BrowseContract.kt'
        jar = Path(directory) / 'browse-contract.jar'
        source.write_text(harness)
        subprocess.run([kotlinc, str(source), '-include-runtime', '-d', str(jar)], check=True)
        subprocess.run([java, '-jar', str(jar)], check=True)
    print('Mihon native-page coordinates and complete source pages: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
