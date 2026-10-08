#!/usr/bin/env python3
from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt'
ABI_ROOTS = (
    ROOT / 'packages/plugin_host_bridge/android/src/mihonRuntime14/kotlin/eu/kanade/tachiyomi/source/online/HttpSource.kt',
    ROOT / 'packages/plugin_host_bridge/android/src/mihonRuntime16/kotlin/eu/kanade/tachiyomi/source/online/HttpSource.kt',
)


def navigation_and_lifecycle_harness(driver: str) -> str:
    patterns = (
        r'private fun loadComic\(.*?\n    \}',
        r'private fun chapterMessage\(.*?\n    \}',
        r'internal class MihonCatalogOperations \{.*?\n\}',
        r'internal class MihonInvocationTask\(.*?\n\}',
        r'private fun invokeSuspend\(.*?\n\}',
    )
    bodies = []
    for pattern in patterns:
        match = re.search(pattern, driver, re.DOTALL)
        if match is None:
            raise SystemExit(f'Mihon behavior contract could not extract {pattern}')
        bodies.append(match.group(0))
    return r'''package dev.zic.pluginhost
import java.lang.reflect.Method
import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.locks.ReentrantLock
import kotlin.coroutines.Continuation
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

private class JSONObject {
    private val fields = LinkedHashMap<String, Any?>()
    fun put(key: String, value: Any?): JSONObject { fields[key] = value; return this }
    override fun toString(): String = fields.toString()
}
private data class FixtureChapter(val name: String, val url: String)
private data class MihonComicCatalog(
    val manga: Any, val chapters: List<Any>, val chapterFailure: Throwable?,
)
private val fixtureChapters: List<Any> = listOf(
    FixtureChapter("第6话", "/six"),
    FixtureChapter("第5话", "/five"),
    FixtureChapter("第4话", "/four"),
)
private var remembered: List<Any> = emptyList()
private fun loadMihonComicCatalog(source: Any, comicId: String, requestId: String) =
    MihonComicCatalog(Any(), fixtureChapters, null)
private fun Any.readValue(vararg names: String): Any? = "source"
private fun Any.readString(vararg names: String): String? {
    val chapter = this as FixtureChapter
    return if ("url" in names) chapter.url else chapter.name
}
private fun Any.readLong(vararg names: String): Long? = null
private fun mihonModelJson(chapter: Any): JSONObject {
    val value = chapter as FixtureChapter
    return JSONObject().put("name", value.name).put("url", value.url)
}
private fun encodeOpaque(kind: String, json: JSONObject): String = kind + ":" + json
private fun formatInstant(value: Long): String = value.toString()
private fun mihonTransportRevision(sourceId: String, source: Any): String? = null
private fun comicMessage(source: Any, manga: Any, comicId: String): Map<String, Any?> = emptyMap()
private fun rememberMihonChapters(
    source: Any, comicId: String, chapters: List<Any>, messages: List<Map<String, Any?>>,
) { remembered = chapters }
''' + '\n\n'.join(bodies) + r'''

private class SuspendedSource {
    val entered = CountDownLatch(1)
    lateinit var continuation: Continuation<Any?>
    fun update(continuation: Continuation<Any?>): Any {
        this.continuation = continuation
        entered.countDown()
        return kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
    }
}
private fun awaitWaiting(thread: Thread, entered: CountDownLatch) {
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
    while (thread.state != Thread.State.WAITING &&
           thread.state != Thread.State.TIMED_WAITING && entered.count != 0L) {
        check(System.nanoTime() < deadline)
        Thread.yield()
    }
}
fun main() {
    val result = loadComic(Any(), "comic", "request")
    @Suppress("UNCHECKED_CAST")
    val chapters = result.getValue("chapters") as List<Map<String, Any?>>
    check(chapters.map { it["sequence"] } == listOf(2, 1, 0))
    check(chapters.sortedBy { it["sequence"] as Int }.map { it["title"] } ==
          listOf("第4话", "第5话", "第6话"))
    check(remembered === fixtureChapters)
    val legacy = chapterMessage(fixtureChapters[0], "comic", 0)
    val projected = chapterMessage(fixtureChapters[0], "comic", 0, logicalSequence = 2)
    check(legacy["chapterId"] == projected["chapterId"])
    check(legacy["sourceRevision"] == projected["sourceRevision"])
    check(projected["sequence"] == 2)

    val operations = MihonCatalogOperations()
    val suspended = SuspendedSource()
    val method = suspended.javaClass.getDeclaredMethod("update", Continuation::class.java)
    method.isAccessible = true
    val retirements = AtomicInteger()
    val interruptedAfterDrain = AtomicBoolean()
    val invocation = MihonInvocationTask(Callable {
        operations.exclusive("source/manga") {
            invokeSuspend(suspended, method, emptyList())
            interruptedAfterDrain.set(Thread.currentThread().isInterrupted)
        }
        Unit
    }) { retirements.incrementAndGet() }
    val owner = Thread(invocation)
    owner.start()
    check(suspended.entered.await(5, TimeUnit.SECONDS))
    invocation.cancel(true)
    check(retirements.get() == 0)

    val followerEntered = CountDownLatch(1)
    val follower = Thread {
        operations.exclusive("source/manga") { followerEntered.countDown() }
    }
    follower.start()
    awaitWaiting(follower, followerEntered)
    check(followerEntered.count == 1L)
    // Different manga remains independent; exclusion is not a global queue.
    check(operations.exclusive("source/another-manga") { 7 } == 7)

    val cancelledEntered = CountDownLatch(1)
    val cancelledRetirements = AtomicInteger()
    val cancelledWaiter = MihonInvocationTask(Callable {
        operations.exclusive("source/manga") { cancelledEntered.countDown() }
        Unit
    }) { cancelledRetirements.incrementAndGet() }
    val cancelledThread = Thread(cancelledWaiter)
    cancelledThread.start()
    awaitWaiting(cancelledThread, cancelledEntered)
    cancelledWaiter.cancel(true)
    cancelledThread.join(5000)
    check(!cancelledThread.isAlive)
    check(cancelledEntered.count == 1L && cancelledRetirements.get() == 1)
    check(followerEntered.count == 1L && retirements.get() == 0)

    suspended.continuation.resumeWith(Result.success("complete"))
    owner.join(5000)
    follower.join(5000)
    check(!owner.isAlive && !follower.isAlive)
    check(retirements.get() == 1 && interruptedAfterDrain.get())
    check(followerEntered.count == 0L)
    check(runCatching { operations.exclusive("failure") { error("source failure") } }.isFailure)
    check(operations.exclusive("failure") { 9 } == 9)

    val queuedRetirements = AtomicInteger()
    val queuedRuns = AtomicInteger()
    val queued = MihonInvocationTask(Callable { queuedRuns.incrementAndGet(); Unit }) {
        queuedRetirements.incrementAndGet()
    }
    queued.cancel(false)
    queued.run()
    check(queuedRuns.get() == 0 && queuedRetirements.get() == 1)
}
'''


def catalog_input_harness(driver: str) -> str:
    parts = []
    for pattern in (
        r'internal fun mihonMangaInput\(.*?\n\}',
        r'private fun mihonComicCatalogKey\(.*?\n    \}',
        r'private fun fetchMihonComicCatalog\(.*?\n    \}',
        r'private fun mihonChapterCatalogFailure\(.*?\n    \).also \{.*?\n',
        r'private fun Throwable.isMihonCapabilityAbsence\(\).*?\n\}',
    ):
        match = re.search(pattern, driver, re.DOTALL)
        if match is None:
            raise SystemExit(f'Mihon catalog input contract could not extract {pattern}')
        parts.append(match.group(0))
    shim = ROOT / 'packages/plugin_host_bridge/android/src/mihonRuntime16/kotlin/eu/kanade/tachiyomi/source/CatalogueSource.kt'
    match = re.search(r'    override suspend fun getMangaUpdate\(.*?\n    \}', shim.read_text(), re.DOTALL)
    if match is None:
        raise SystemExit('Mihon current compatibility update could not be extracted')
    return r'''package dev.zic.pluginhost
import java.io.IOException
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine

internal class JSONObject {
    val fields = mutableMapOf<String, Any>()
    fun put(key: String, value: Any): JSONObject = apply { fields[key] = value }
    fun optString(key: String): String = fields[key] as? String ?: ""
}
private class RawManga(val url: String)
private class CompleteChapter(val url: String, val memo: String)
private data class Combined(val manga: Any, val chapters: List<Any>)
private data class MihonComicCatalog(
    val manga: Any, val chapters: List<Any>, val chapterFailure: Throwable?,
)
private val rawManga = RawManga("request-only-identity")
private val detailedManga = RawManga("")
private val completeChapters: List<Any> = (0 until 80).map {
    CompleteChapter("same-url", "memo-$it")
}
private class FixtureSource(val legacy: Boolean = false, val failure: Throwable? = null) {
    val calls = mutableListOf<String>()
}
private val opaqueManga = JSONObject()
    .put("url", "opaque-source-url")
    .put("title", "source-title")
    .put("description", "source-description")
    .put("memo", "source-request-state")
private fun decodeOpaque(value: String, kind: String): JSONObject {
    require(value == "mihon:manga:fixture" && kind == "manga")
    return opaqueManga
}
private fun createModel(loader: ClassLoader, type: String, encoded: JSONObject): Any = rawManga
private fun cachedMihonChaptersForComic(source: Any, comicId: String): List<Any> = completeChapters
private fun mihonSourceCacheKey(source: Any): String = "fixture-source"
private fun ensureNotCancelled(requestId: String) {}
private fun Any.invokeMihonCompatible(method: String, args: List<Any>): Any {
    val source = this as FixtureSource
    source.calls += method
    when (method) {
        "getMangaUpdate" -> {
            check(args[0] === rawManga)
            check(args[1] === completeChapters)
            check(args[2] == true && args[3] == true)
            source.failure?.let { throw it }
            if (source.legacy) throw NoSuchMethodException("combined unavailable")
            return Combined(detailedManga, completeChapters)
        }
        "fetchMangaDetails" -> { check(args.single() === rawManga); return detailedManga }
        "fetchChapterList" -> { check(args.single() === rawManga); return completeChapters }
        else -> error("unexpected catalog call")
    }
}
private fun Any?.unwrapAsync(): Any = requireNotNull(this)
private fun Any.asObjectList(): List<Any> = this as List<Any>
private fun Any.readValue(vararg names: String): Any = (this as Combined).manga
private fun Any.readList(vararg names: String): List<Any> = (this as Combined).chapters
private fun Throwable.rootCause(): Throwable = generateSequence(this) { it.cause }.last()
''' + '\n\n'.join(parts) + r'''

private class SManga(val url: String)
private class SChapter(val url: String, val memo: String)
private data class SMangaUpdate(val manga: SManga, val chapters: List<SChapter>)
private class FixtureObservable<T>(val value: T)
private suspend fun <T> FixtureObservable<T>.awaitSingleCompat(): T = value
private interface UpdateContract {
    suspend fun getMangaUpdate(
        manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean,
    ): SMangaUpdate
}
private class CompatSource(private val original: SManga, val result: List<SChapter>) : UpdateContract {
    val detailed = SManga("")
    val calls = mutableListOf<String>()
    private fun fetchMangaDetails(manga: SManga): FixtureObservable<SManga> {
        check(manga === original)
        calls += "details"
        return FixtureObservable(detailed)
    }
    private fun fetchChapterList(manga: SManga): FixtureObservable<List<SChapter>> {
        check(manga === original) { "chapter query received detailed model instead of raw manga" }
        calls += "chapters"
        return FixtureObservable(result)
    }
''' + match.group(0) + r'''
}
private fun immediate(block: suspend () -> SMangaUpdate): SMangaUpdate {
    var completion: Result<SMangaUpdate>? = null
    block.startCoroutine(object : Continuation<SMangaUpdate> {
        override val context = EmptyCoroutineContext
        override fun resumeWith(result: Result<SMangaUpdate>) { completion = result }
    })
    return requireNotNull(completion).getOrThrow()
}
fun main() {
    val nativeUrl = "/album/1236711/开花岛-极欲绽放之村"
    val nativeInput = mihonMangaInput(nativeUrl)
    check(nativeInput.fields == mapOf("kind" to "manga", "url" to nativeUrl, "title" to ""))
    check(mihonMangaInput("mihon:manga:fixture") === opaqueManga)
    check(opaqueManga.fields["memo"] == "source-request-state")
    check(mihonComicCatalogKey(FixtureSource(), "opaque-source-url") ==
          mihonComicCatalogKey(FixtureSource(), "mihon:manga:fixture"))
    for (invalid in listOf("", "   ", "mihon:chapter:fixture", "mihon:resource:fixture")) {
        check(runCatching { mihonMangaInput(invalid) }.exceptionOrNull() is IllegalArgumentException)
    }
    val current = FixtureSource()
    val combined = fetchMihonComicCatalog(current, "raw-input", "request")
    check(current.calls == listOf("getMangaUpdate"))
    check(combined.manga === detailedManga && combined.chapters === completeChapters)
    check(combined.chapters.size == 80 && combined.chapterFailure == null)
    // Same URL is not sufficient to fold distinct complete source models.
    check((combined.chapters[0] as CompleteChapter).memo !=
          (combined.chapters[1] as CompleteChapter).memo)

    val legacy = FixtureSource(legacy = true)
    val legacyCatalog = fetchMihonComicCatalog(legacy, "raw-input", "request")
    check(legacy.calls == listOf("getMangaUpdate", "fetchMangaDetails", "fetchChapterList"))
    check(legacyCatalog.chapters === completeChapters && legacyCatalog.manga === detailedManga)
    for (failure in listOf(IOException("source network failure"), UnsupportedOperationException("parser failure"))) {
        val failed = FixtureSource(failure = failure)
        val catalog = fetchMihonComicCatalog(failed, "raw-input", "request")
        check(failed.calls == listOf("getMangaUpdate"))
        check(catalog.chapterFailure?.cause === failure && catalog.chapters.isEmpty())
    }

    val input = SManga("raw-request-state")
    val chapters = (0 until 80).map { SChapter("same-url", "memo-$it") }
    val compatibility = CompatSource(input, chapters)
    val result = immediate { compatibility.getMangaUpdate(input, emptyList(), true, true) }
    check(compatibility.calls == listOf("details", "chapters"))
    check(result.manga === compatibility.detailed && result.chapters === chapters)
    val retained = immediate { compatibility.getMangaUpdate(input, chapters, false, false) }
    check(retained.manga === input && retained.chapters === chapters)
    check(compatibility.calls == listOf("details", "chapters"))
    println("Mihon raw manga/current+legacy catalog input and complete chapters: OK")
}
'''


def main() -> int:
    raw_driver = DRIVER.read_bytes()
    if b'\x00' in raw_driver:
        raise SystemExit('Mihon runtime source contains an embedded NUL byte')
    driver = raw_driver.decode()
    required = (
        'catalog.chapterFailure?.let { throw it }',
        'val combined = try',
        'listOf(manga, existingChapters, true, true)',
        'source.invokeMihonCompatible("fetchChapterList", listOf(manga))',
        'source.invokeMihonCompatible("getPageList", listOf(chapter))',
        'source.invokeMihonCompatible("fetchPageList", listOf(chapter))',
        'val existingChapters = cachedMihonChaptersForComic(source, comicId)',
        'private fun mihonSourceCacheKey(source: Any): String',
        'private fun mihonChapterCacheKey(source: Any, chapterId: String): String',
        'chapterById[mihonChapterCacheKey(source, chapterId)]',
        'Mihon source exposes no compatible chapter-catalog operation',
        'Mihon source exposes no compatible page-list operation',
        'cause !is UnsupportedOperationException',
        'loadMihonPageModels(source, chapter, requestId)',
        'mihonCoverResource(source, manga)',
        'mihonRequestResource(source.javaClass.classLoader, request)',
        'mihonContentKindHint(resource.optString("url"))',
        'put("animatedHint", kind == "webp" || kind == "gif")',
        '"blockingGet"',
        '"value"',
    )
    for token in required:
        if token not in driver:
            raise SystemExit(f'Mihon chapter contract is incomplete: {token}')
    # Current Source/TachiyomiX 1.6 enters through getMangaUpdate; the legacy
    # fetchChapterList/fetchPageList APIs are capability fallbacks only.
    combined = driver.index('val combined = try')
    legacy_catalog = driver.index('source.invokeMihonCompatible("fetchChapterList"')
    current_pages = driver.index('source.invokeMihonCompatible("getPageList"')
    legacy_pages = driver.index('source.invokeMihonCompatible("fetchPageList"')
    if combined >= legacy_catalog:
        raise SystemExit('Mihon legacy chapter API still runs before current getMangaUpdate')
    if current_pages >= legacy_pages:
        raise SystemExit('Mihon legacy page API still runs before current getPageList')
    forbidden = (
        'createSyntheticMihonChapter',
        'deduplicateMihonStartReadingEntries',
        'selectMihonChapters',
        'MihonChapterSelection',
        'MIHON_SYNTHETIC_REVISION',
        'detailedManga.readList("chapters"',
        'normalizeMihonStartReadingTitle',
        'normalizeMihonChapterCatalog',
        'mihonChapterMetadataScore',
        'for (candidate in listOf("getChapterList", "fetchChapterList"))',
        'source.invokeMihonCompatible("getChapterList"',
        'source.invokeMihonCompatible("fetchChapterList", listOf(detailedManga))',
        'fetchMangaUpdate',
        '开始阅读"',
    )
    for token in forbidden:
        if token in driver:
            raise SystemExit(f'Mihon chapter contract retains guessed host behavior: {token}')
    if '!chapterProbeCompleted' in driver:
        raise SystemExit('Mihon chapter failures are still hidden behind an empty probe')
    for source in ABI_ROOTS:
        text = source.read_text()
        if 'chapters.onEach { chapter -> prepareNewChapter(chapter, manga) }' not in text:
            raise SystemExit(f'Mihon ABI omits chapter normalization: {source}')

    kotlinc = shutil.which('kotlinc')
    java = shutil.which('java')
    if kotlinc and java:
        unwrap = re.search(
            r'private fun Any\?\.unwrapAsync\(\): Any \{.*?\n\}',
            driver,
            re.DOTALL,
        )
        if unwrap is None:
            raise SystemExit('Mihon async adapter could not be extracted')
        async_harness = f'''package dev.zic.pluginhost
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Future

{unwrap.group(0)}

private class BlockingSingle(private val result: Any) {{ fun value(): Any = result }}
private class Rx1Single(private val result: Any) {{ fun toBlocking(): BlockingSingle = BlockingSingle(result) }}
private class Rx2Single(private val result: Any) {{ fun blockingGet(): Any = result }}

fun main() {{
    check((CompletableFuture.completedFuture(listOf("future")) as Future<*>).unwrapAsync() == listOf("future"))
    check(Rx1Single(listOf("rx1")).unwrapAsync() == listOf("rx1"))
    check(Rx2Single(listOf("rx2")).unwrapAsync() == listOf("rx2"))
}}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'AsyncContract.kt'
            jar = root / 'async-contract.jar'
            source.write_text(async_harness)
            subprocess.run(
                [kotlinc, str(source), '-include-runtime', '-d', str(jar)],
                check=True,
            )
            subprocess.run([java, '-jar', str(jar)], check=True)
            source.write_text(navigation_and_lifecycle_harness(driver))
            subprocess.run(
                [kotlinc, str(source), '-include-runtime', '-d', str(jar)],
                check=True,
            )
            subprocess.run([java, '-jar', str(jar)], check=True)
            source.write_text(catalog_input_harness(driver))
            subprocess.run(
                [kotlinc, str(source), '-include-runtime', '-d', str(jar)],
                check=True,
            )
            subprocess.run([java, '-jar', str(jar)], check=True)

    print('Mihon chapter catalog contract: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
