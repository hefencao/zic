package dev.zic.pluginhost

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.res.AssetManager
import android.content.res.Resources
import android.view.LayoutInflater
import android.os.Build
import android.os.Looper
import android.os.SystemClock
import androidx.preference.EditTextPreference
import androidx.preference.ListPreference
import androidx.preference.MultiSelectListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceGroup
import androidx.preference.PreferenceManager
import androidx.preference.SwitchPreferenceCompat
import androidx.preference.TwoStatePreference
import dalvik.system.DexClassLoader
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.lang.reflect.Method
import java.lang.reflect.Modifier
import java.lang.reflect.Proxy
import java.security.MessageDigest
import java.util.Properties
import java.util.Locale
import java.util.ArrayDeque
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Future
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipFile
import kotlin.coroutines.Continuation
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

/**
 * Reflection adapter for Mihon/Tachiyomi extension APKs.
 *
 * The APK is never installed. It is re-verified, loaded from the runtime
 * process' private directory, and reduced to zic's four catalog operations.
 * Reader/download/cache ownership stays in Dart.
 */
internal class MihonRuntimeDriver private constructor(
    override val driverId: String,
    override val runtimeId: String,
    private val executor: ExecutorService,
    private val sourceById: ConcurrentHashMap<String, Any>,
    private val chapterById: ConcurrentHashMap<String, Any>,
    private val chapterIdsByComic: ConcurrentHashMap<String, Set<String>>,
    private val payloadContext: Context,
    private val runtimeRoot: File,
    private val maxResponseBytes: Int,
    override val sources: List<Map<String, Any?>>,
) : NativeExternalPluginDriver {
    private val cancelled = ConcurrentHashMap.newKeySet<String>()
    private val calls = ConcurrentHashMap<String, Any>()
    private val tasks = ConcurrentHashMap<String, Future<*>>()
    private val completions = ConcurrentHashMap<String, CountDownLatch>()
    private val rateLimiters = ConcurrentHashMap<String, SourceRequestLimiter>()
    private val runtimeTransformBySource = ConcurrentHashMap<String, Boolean>()
    private val realChapterCatalogs = ConcurrentHashMap.newKeySet<String>()
    private val closed = AtomicBoolean(false)
    private val sourcesClosed = AtomicBoolean(false)
    private val runtimeDeleted = AtomicBoolean(false)

    override fun invoke(request: Map<String, Any?>, result: NativeDriverResult) {
        if (closed.get()) {
            result.error("runtime-closing", "Mihon runtime is closing")
            return
        }
        val requestId = request.requireString("requestId")
        val sourceId = request.requireString("externalSourceId")
        val source = sourceById[sourceId]
        if (source == null) {
            result.error("source-missing", "Mihon source is not active")
            return
        }
        val completion = CountDownLatch(1)
        if (completions.putIfAbsent(requestId, completion) != null) {
            result.error("runtime-request-duplicate", "Mihon request id is already active")
            return
        }
        val responded = AtomicBoolean(false)
        val task = object : FutureTask<Unit>(Callable {
            try {
                ensureNotCancelled(requestId)
                val arguments = request["arguments"].stringMap("runtime request arguments")
                val operation = request.requireString("operation")
                if (operation in rateLimitedMihonOperations) {
                    enforceSourceRequestLimit(sourceId, source)
                }
                val payload = when (operation) {
                    "browse" -> browse(source, arguments, requestId)
                    "loadComic" -> loadComic(source, arguments.requireString("comicId"), requestId)
                    "loadChapter" -> loadChapter(source, arguments.requireString("chapterId"), requestId)
                    "loadResource" -> loadResource(source, arguments.requireString("uri"), requestId)
                    "resolveResource" -> resolveResource(
                        sourceId,
                        source,
                        arguments.requireString("uri"),
                    )
                    "loadSourceSettings" -> loadSourceSettings(source)
                    "updateSourceSetting" -> updateSourceSetting(
                        source,
                        arguments.requireString("key"),
                        arguments["value"],
                    )
                    else -> error("unsupported Mihon runtime operation")
                }
                ensureNotCancelled(requestId)
                if (responded.compareAndSet(false, true)) result.success(payload)
            } catch (error: Throwable) {
                val cause = error.rootCause()
                val cancelledRequest = cancelled.contains(requestId) || cause is InterruptedException
                if (responded.compareAndSet(false, true)) {
                    val verificationRequired = !cancelledRequest && error.isSourceVerificationFailure()
                    result.error(
                        when {
                            cancelledRequest -> "runtime-request-cancelled"
                            verificationRequired -> "source-verification-required"
                            else -> "mihon-operation-failed"
                        },
                        if (cancelledRequest) {
                            "Mihon request was cancelled"
                        } else {
                            error.mihonDiagnosticMessage()
                        },
                        retryable = !cancelledRequest && cause.isNetworkFailure(),
                    )
                }
            }
        }) {
            override fun done() {
                if (isCancelled && responded.compareAndSet(false, true)) {
                    result.error("runtime-request-cancelled", "Mihon request was cancelled")
                }
                calls.remove(requestId)
                tasks.remove(requestId, this)
                cancelled.remove(requestId)
                completions.remove(requestId, completion)
                completion.countDown()
                finalizeCloseIfIdle()
            }
        }
        tasks[requestId] = task
        if (closed.get()) {
            task.cancel(false)
            return
        }
        try {
            executor.execute(task)
        } catch (error: Throwable) {
            tasks.remove(requestId, task)
            completions.remove(requestId, completion)
            cancelled.remove(requestId)
            completion.countDown()
            if (responded.compareAndSet(false, true)) {
                result.error("runtime-closing", error.sanitizedMessage())
            }
            finalizeCloseIfIdle()
        }
    }

    override fun cancel(requestId: String) {
        if (!completions.containsKey(requestId)) return
        cancelled.add(requestId)
        when (val call = calls.remove(requestId)) {
            is HttpURLConnection -> call.disconnect()
            null -> Unit
            else -> call.invokeOptional("cancel")
        }
        tasks.remove(requestId)?.cancel(true)
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        tasks.keys.toList().forEach(::cancel)
        if (Looper.myLooper() != Looper.getMainLooper()) {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            completions.values.toList().forEach { completion ->
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0) return@forEach
                runCatching { completion.await(remaining, TimeUnit.NANOSECONDS) }
            }
        }
        finalizeCloseIfIdle()
    }

    private fun finalizeCloseIfIdle() {
        if (!closed.get() || completions.isNotEmpty()) return
        if (sourcesClosed.compareAndSet(false, true)) {
            sourceById.values.distinctBy { System.identityHashCode(it) }.forEach { source ->
                runCatching { source.invokeOptional("close") }
            }
            sourceById.clear()
            chapterById.clear()
            chapterIdsByComic.clear()
        }
        if (runtimeDeleted.compareAndSet(false, true)) {
            runtimeRoot.deleteRecursively()
        }
    }

    private fun browse(
        source: Any,
        arguments: Map<String, Any?>,
        requestId: String,
    ): Map<String, Any?> {
        val query = arguments["query"] as? String ?: ""
        val offset = arguments.nonNegativeInt("offset")
        val limit = arguments.positiveInt("limit")
        val page = (offset / limit) + 1
        val pageResult = if (query.isBlank()) {
            source.invokeFirst(
                listOf(
                    Invocation("getPopularManga", listOf(page)),
                    Invocation("fetchPopularManga", listOf(page)),
                ),
            )
        } else {
            val filters = source.invokeOptional("getFilterList") ?: emptyFilterList(source.javaClass.classLoader)
            source.invokeFirst(
                listOf(
                    Invocation("getSearchMangaList", listOf(page, query, filters)),
                    Invocation("getSearchManga", listOf(page, query, filters)),
                    Invocation("fetchSearchManga", listOf(page, query, filters)),
                ),
            )
        }.unwrapAsync()
        ensureNotCancelled(requestId)
        val mangas = pageResult.readList("mangas", "getMangas")
        val hasNext = pageResult.readBoolean("hasNextPage", "getHasNextPage") ?: (mangas.size >= limit)
        val sliced = mangas.drop(offset % limit).take(limit)
        return mapOf(
            "items" to sliced.map { manga -> mangaSummary(source, manga) },
            "offset" to offset,
            "hasMore" to (hasNext || mangas.size > (offset % limit) + sliced.size),
        )
    }

    private fun loadComic(source: Any, comicId: String, requestId: String): Map<String, Any?> {
        val catalog = loadMihonComicCatalog(source, comicId, requestId)
        // A failed chapter request is not evidence that this is a gallery with
        // no chapters. Do not hide a real source/network failure behind the
        // synthetic single-chapter fallback (this used to make JMComic appear
        // to have one "正文" chapter while dropping its real catalog).
        catalog.chapterFailure?.let { throw it }
        val sourceId = source.readValue("id", "getId")?.toString()
            ?: error("Mihon source id is missing")
        val transportRevision = mihonTransportRevision(sourceId, source)
        val catalogIdentity = "$sourceId\u0000$comicId"
        val selectedChapters = selectMihonChapters(
            chapters = catalog.chapters,
            allowSynthetic = !catalog.chapterCatalogAvailable &&
                !realChapterCatalogs.contains(catalogIdentity),
        ) {
            createSyntheticMihonChapter(source, catalog.manga)
        }
        if (!selectedChapters.synthetic && selectedChapters.chapters.isNotEmpty()) {
            realChapterCatalogs += catalogIdentity
        }
        val syntheticPageCount = if (selectedChapters.synthetic) {
            loadMihonPageModels(source, selectedChapters.chapters.single(), requestId).size
                .also { count ->
                    require(count > 0) {
                        "Mihon source exposed neither a chapter catalog nor readable gallery pages"
                    }
            }
        } else {
            null
        }
        val chapterMessages = selectedChapters.chapters.mapIndexed { index, chapter ->
            chapterMessage(
                chapter = chapter,
                comicId = comicId,
                sequence = index,
                synthetic = selectedChapters.synthetic,
                pageCount = syntheticPageCount,
                transportRevision = transportRevision,
            )
        }
        rememberMihonChapters(comicId, selectedChapters.chapters, chapterMessages)
        return mapOf(
            "comic" to comicMessage(source, catalog.manga, comicId),
            "chapters" to chapterMessages,
        )
    }

    private fun loadMihonComicCatalog(
        source: Any,
        comicId: String,
        requestId: String,
    ): MihonComicCatalog {
        val encoded = decodeOpaque(comicId, "manga")
        val manga = createModel(
            source.javaClass.classLoader,
            "eu.kanade.tachiyomi.source.model.SManga",
            encoded,
        )
        val failures = mutableListOf<Throwable>()
        val update = try {
            source.invokeFirst(
                listOf(
                    Invocation("getMangaUpdate", listOf(manga, emptyList<Any>(), true, true)),
                    Invocation("fetchMangaUpdate", listOf(manga, emptyList<Any>(), true, true)),
                ),
            ).unwrapAsync()
        } catch (error: Throwable) {
            if (error.isMihonCapabilityAbsence()) {
                null
            } else {
                // Some extensions were built against the combined API but
                // still only implement the legacy detail/chapter methods.
                // Keep the failure and try those methods before giving up.
                failures += error
                null
            }
        }
        ensureNotCancelled(requestId)
        val detailedManga = update?.readValue("manga", "getManga") ?: try {
            source.invokeFirst(
                listOf(
                    Invocation("getMangaDetails", listOf(manga)),
                    Invocation("fetchMangaDetails", listOf(manga)),
                ),
            ).unwrapAsync()
        } catch (error: Throwable) {
            if (error.isMihonCapabilityAbsence()) {
                manga
            } else {
                failures += error
                manga
            }
        }
        ensureNotCancelled(requestId)

        // Mihon 1.6 exposes details and chapters atomically through
        // SMangaUpdate. A non-empty combined chapter result is authoritative;
        // asking the source for the chapter list again duplicates a potentially
        // non-idempotent extension operation.
        val updateChapters = update
            ?.readList("chapters", "getChapters", "newChapters", "getNewChapters")
            .orEmpty()
        val detailedChapters = detailedManga
            .readList("chapters", "getChapters", "chapterList", "getChapterList")
        val chapterFailures = failures
        var compatibilityChapters = emptyList<Any>()
        // A successful combined SMangaUpdate call proves that this source has
        // an authoritative chapter-catalog capability even when it returns an
        // empty list. Empty is not evidence for a gallery fallback.
        var chapterCatalogAvailable = update != null
        if (updateChapters.isEmpty() && detailedChapters.isEmpty()) {
            val chapterModels = buildList {
                add(detailedManga)
                if (manga !== detailedManga) add(manga)
            }
            chapterSearch@ for (chapterModel in chapterModels) {
                for (candidate in listOf("getChapterList", "fetchChapterList")) {
                    val loaded = try {
                        source.invokeMihonCompatible(candidate, listOf(chapterModel))
                            .unwrapAsync()
                            .asObjectList()
                    } catch (error: Throwable) {
                        if (error.isMihonCapabilityAbsence()) continue
                        chapterFailures += error
                        continue
                    }
                    chapterCatalogAvailable = true
                    ensureNotCancelled(requestId)
                    if (loaded.isNotEmpty()) {
                        compatibilityChapters = loaded
                        break@chapterSearch
                    }
                }
            }
        }
        val chapters = when {
            updateChapters.isNotEmpty() -> updateChapters
            detailedChapters.isNotEmpty() -> detailedChapters
            compatibilityChapters.isNotEmpty() -> compatibilityChapters
            else -> emptyList()
        }
        val chapterFailure = if (chapters.isEmpty() && chapterFailures.isNotEmpty()) {
            IllegalStateException(
                "Mihon chapter catalog failed for ${source.javaClass.name}",
                chapterFailures.first(),
            ).also { failure ->
                chapterFailures.drop(1).forEach(failure::addSuppressed)
            }
        } else {
            null
        }
        return MihonComicCatalog(
            manga = detailedManga,
            chapters = chapters,
            chapterFailure = chapterFailure,
            chapterCatalogAvailable = chapterCatalogAvailable,
        )
    }

    private fun createSyntheticMihonChapter(source: Any, manga: Any): Any {
        val chapter = createModel(
            source.javaClass.classLoader,
            "eu.kanade.tachiyomi.source.model.SChapter",
            JSONObject()
                .put("url", manga.readString("url", "getUrl").orEmpty())
                .put("name", "正文")
                .put("chapter_number", 1f)
                .put("date_upload", 0L)
                .put("scanlator", ""),
        )
        runCatching {
            source.invokeMihonCompatible("prepareNewChapter", listOf(chapter, manga))
        }
        return chapter
    }

    private fun rememberMihonChapters(
        comicId: String,
        chapters: List<Any>,
        messages: List<Map<String, Any?>>,
    ) {
        val ids = messages.map { message -> message.getValue("chapterId") as String }.toSet()
        synchronized(chapterById) {
            chapterIdsByComic.put(comicId, ids)
                ?.filterNot { id -> ids.contains(id) }
                ?.forEach { id -> chapterById.remove(id) }
            chapters.zip(messages).forEach { (chapter, message) ->
                chapterById[message.getValue("chapterId") as String] = chapter
            }
            while (chapterById.size > MAX_CACHED_MIHON_CHAPTERS) {
                val evictedComicId = chapterIdsByComic.keys.firstOrNull { it != comicId } ?: break
                chapterIdsByComic.remove(evictedComicId)
                    ?.forEach { id -> chapterById.remove(id) }
            }
        }
    }

    private fun resolveMihonChapter(
        source: Any,
        chapterId: String,
        encoded: JSONObject,
        requestId: String,
    ): Any {
        chapterById[chapterId]?.let { return it }
        val comicId = encoded.optString("comicId")
        require(comicId.isNotBlank()) { "chapter comic identity is missing" }
        val sourceId = source.readValue("id", "getId")?.toString()
            ?: error("Mihon source id is missing")
        val catalogIdentity = "$sourceId\u0000$comicId"
        if (encoded.optBoolean("synthetic")) {
            require(!realChapterCatalogs.contains(catalogIdentity)) {
                "Mihon synthetic chapter is invalid after a real catalog was observed"
            }
            val manga = createModel(
                source.javaClass.classLoader,
                "eu.kanade.tachiyomi.source.model.SManga",
                decodeOpaque(comicId, "manga"),
            )
            return createModel(
                source.javaClass.classLoader,
                "eu.kanade.tachiyomi.source.model.SChapter",
                encoded,
            ).also { chapter ->
                runCatching {
                    source.invokeMihonCompatible("prepareNewChapter", listOf(chapter, manga))
                }
            }
        }
        val catalog = loadMihonComicCatalog(source, comicId, requestId)
        catalog.chapterFailure?.let { throw it }
        val selectedChapters = selectMihonChapters(
            chapters = catalog.chapters,
            allowSynthetic = !catalog.chapterCatalogAvailable &&
                !realChapterCatalogs.contains(catalogIdentity),
        ) {
            createSyntheticMihonChapter(source, catalog.manga)
        }
        if (!selectedChapters.synthetic && selectedChapters.chapters.isNotEmpty()) {
            realChapterCatalogs += catalogIdentity
        }
        val messages = selectedChapters.chapters.mapIndexed { index, chapter ->
            chapterMessage(
                chapter = chapter,
                comicId = comicId,
                sequence = index,
                synthetic = selectedChapters.synthetic,
            )
        }
        rememberMihonChapters(comicId, selectedChapters.chapters, messages)
        chapterById[chapterId]?.let { return it }
        val matches = selectedChapters.chapters.filter { chapter ->
            mihonChapterMatches(chapter, encoded)
        }
        require(matches.size == 1) {
            if (matches.isEmpty()) {
                "Mihon chapter is no longer present in the source catalog"
            } else {
                "Mihon chapter identity is ambiguous after source refresh"
            }
        }
        return matches.single().also { chapterById[chapterId] = it }
    }

    private fun loadMihonPageModels(
        source: Any,
        chapter: Any,
        requestId: String,
    ): List<Any> {
        val failures = mutableListOf<Throwable>()
        var completed = false
        for (candidate in listOf("getPageList", "fetchPageList")) {
            val pages = try {
                source.invokeMihonCompatible(candidate, listOf(chapter))
                    .unwrapAsync()
                    .asObjectList()
            } catch (error: Throwable) {
                val cause = error.rootCause()
                if (error is NoSuchMethodException ||
                    cause is NoSuchMethodException ||
                    cause is UnsupportedOperationException
                ) {
                    continue
                }
                failures += error
                continue
            }
            completed = true
            ensureNotCancelled(requestId)
            if (pages.isNotEmpty()) return pages
        }
        if (failures.isNotEmpty()) {
            throw IllegalStateException(
                "Mihon page list failed for ${source.javaClass.name}",
                failures.first(),
            ).also { failure ->
                failures.drop(1).forEach(failure::addSuppressed)
            }
        }
        check(completed) {
            "Mihon source exposes no compatible page-list operation"
        }
        return emptyList()
    }

    private fun loadChapter(source: Any, chapterId: String, requestId: String): Map<String, Any?> {
        val encoded = decodeOpaque(chapterId, "chapter")
        val comicId = encoded.optString("comicId")
        require(comicId.isNotBlank()) { "chapter comic identity is missing" }
        val chapter = resolveMihonChapter(source, chapterId, encoded, requestId)
        val pages = loadMihonPageModels(source, chapter, requestId)
        require(pages.isNotEmpty()) { "Mihon chapter contains no readable pages" }
        val pageMessages = pages.mapIndexed { index, page ->
            val resource = mihonPageResource(source, page, index)
            val uri = encodeOpaque(
                "resource",
                resource,
            )
            mutableMapOf<String, Any?>(
                "chapterId" to chapterId,
                "pageId" to "${chapterId}:$index",
                "index" to index,
                "uri" to uri,
            ).apply {
                mihonContentKindHint(resource.optString("url"))?.let { kind ->
                    put("contentKindHint", kind)
                    put("animatedHint", kind == "webp" || kind == "gif")
                }
            }
        }
        val sourceId = source.readValue("id", "getId")?.toString()
            ?: error("Mihon source id is missing")
        val resolvedChapter = chapterMessage(
            chapter = chapter,
            comicId = comicId,
            sequence = encoded.optInt("sequence", 0),
            synthetic = encoded.optBoolean("synthetic"),
            transportRevision = mihonTransportRevision(sourceId, source),
        ).toMutableMap().apply {
            put("chapterId", chapterId)
            put("pageCount", pageMessages.size)
        }
        return mapOf(
            "comicId" to comicId,
            "chapter" to resolvedChapter,
            "pages" to pageMessages,
            "readingDirection" to "vertical",
        )
    }

    private fun mihonContentKindHint(url: String): String? {
        val path = url.substringBefore('?').substringBefore('#').lowercase(Locale.US)
        return when {
            path.endsWith(".webp") -> "webp"
            path.endsWith(".gif") -> "gif"
            path.endsWith(".png") -> "png"
            path.endsWith(".jpg") || path.endsWith(".jpeg") || path.endsWith(".jpe") -> "jpeg"
            path.endsWith(".avif") -> "avif"
            else -> null
        }
    }

    private fun mihonTransportRevision(sourceId: String, source: Any): String? =
        if (runtimeTransformBySource.computeIfAbsent(sourceId) {
                mihonSourceRequiresRuntimeTransform(source)
            }) {
            MIHON_RUNTIME_TRANSFORM_REVISION
        } else {
            null
        }

    private fun resolveResource(
        sourceId: String,
        source: Any,
        uri: String,
    ): Map<String, Any?> {
        val resource = if (uri.startsWith("mihon:resource:")) {
            decodeOpaque(uri, "resource")
        } else {
            require(uri.startsWith("https://") || uri.startsWith("http://")) {
                "Mihon resource URI must use a runtime token or HTTP(S)"
            }
            JSONObject().put("url", uri)
        }
        val resolvedResource = if (resource.optBoolean("deferredPage")) {
            enforceSourceRequestLimit(sourceId, source)
            resolveDeferredMihonPageResource(source, resource)
        } else {
            resource
        }
        val resourceUrl = resolvedResource.getString("url")
        val headers = resolvedResource.optJSONObject("headers").stringMap()
            .ifEmpty { source.readValue("headers", "getHeaders").stringHeaders() }
        val requiresRuntimeTransform = mihonTransportRevision(sourceId, source) != null
        return mapOf(
            "url" to resourceUrl,
            "method" to "GET",
            "headers" to headers,
            "body" to null,
            "requiresRuntimeTransform" to requiresRuntimeTransform,
        )
    }

    private fun loadResource(source: Any, uri: String, requestId: String): ByteArray {
        val resource = if (uri.startsWith("mihon:resource:")) {
            decodeOpaque(uri, "resource")
        } else {
            require(uri.startsWith("https://") || uri.startsWith("http://")) {
                "Mihon resource URI must use a runtime token or HTTP(S)"
            }
            JSONObject().put("url", uri)
        }
        val resolvedResource = if (resource.optBoolean("deferredPage")) {
            resolveDeferredMihonPageResource(source, resource)
        } else {
            resource
        }
        val resourceUrl = resolvedResource.getString("url")
        val headers = resolvedResource.optJSONObject("headers").stringMap()
            .ifEmpty { source.readValue("headers", "getHeaders").stringHeaders() }
        val client = source.readValue("client", "getClient")
        if (client == null) {
            return loadResourceWithPlatformNetwork(resourceUrl, headers, requestId)
        }
        val loader = source.javaClass.classLoader
        val requestBuilderType = Class.forName("okhttp3.Request\$Builder", true, loader)
        val builder = requestBuilderType.getDeclaredConstructor().newInstance()
        builder.invokeCompatible("url", listOf(resourceUrl))
        headers.forEach { (name, value) ->
            builder.invokeCompatible("header", listOf(name, value))
        }
        val request = builder.invokeCompatible("build", emptyList())
            ?: error("Mihon request builder returned no request")
        val call = client.invokeCompatible("newCall", listOf(request))
            ?: error("Mihon client returned no call")
        calls[requestId] = call
        val response = call.invokeCompatible("execute", emptyList())
            ?: error("Mihon resource response is empty")
        try {
            ensureNotCancelled(requestId)
            val successful = response.readBoolean("isSuccessful", "getIsSuccessful") ?: false
            val code = response.readLong("code", "getCode") ?: 0
            if (!successful) error("Mihon resource HTTP $code")
            val body = response.readValue("body", "getBody")
                ?: error("Mihon resource response body is empty")
            val bytes = body.invokeCompatible("bytes", emptyList()) as? ByteArray
                ?: error("Mihon resource body did not return bytes")
            require(bytes.size <= maxResponseBytes) {
                "Mihon response exceeds runtime limit"
            }
            return bytes
        } finally {
            calls.remove(requestId)
            runCatching { response.invokeOptional("close") }
        }
    }

    private fun loadSourceSettings(source: Any): List<Map<String, Any?>> {
        val preferences = sourcePreferences(source)
        val extension = createSourcePreferenceScreen(source)
            ?.flattenPreferences()
            ?.mapNotNull(::preferenceMessage)
            ?.toList()
            .orEmpty()
        return extension + listOf(
            mapOf(
                "key" to ZIC_REQUEST_LIMIT_KEY,
                "title" to "限制时间内允许的请求数",
                "summary" to "0 表示不限制；漫画列表、章节和图片请求均计数",
                "kind" to "text",
                "value" to preferences.getInt(ZIC_REQUEST_LIMIT_KEY, 0).toString(),
                "sensitive" to false,
                "choices" to emptyList<Map<String, String>>(),
            ),
            mapOf(
                "key" to ZIC_REQUEST_PERIOD_KEY,
                "title" to "请求限制时间（秒）",
                "summary" to "范围 1–3600 秒",
                "kind" to "text",
                "value" to preferences.getInt(ZIC_REQUEST_PERIOD_KEY, 60).toString(),
                "sensitive" to false,
                "choices" to emptyList<Map<String, String>>(),
            ),
        )
    }

    private fun updateSourceSetting(source: Any, key: String, value: Any?): Map<String, Any?> {
        if (key == ZIC_REQUEST_LIMIT_KEY || key == ZIC_REQUEST_PERIOD_KEY) {
            val parsed = (value as? String)?.toIntOrNull()
                ?: error("Mihon request limit preference requires an integer")
            if (key == ZIC_REQUEST_LIMIT_KEY) {
                require(parsed in 0..1000) { "Request limit must be between 0 and 1000" }
            } else {
                require(parsed in 1..3600) { "Request period must be between 1 and 3600 seconds" }
            }
            sourcePreferences(source).edit().putInt(key, parsed).apply()
            rateLimiters.remove(source.readValue("id", "getId").toString())
            return emptyMap()
        }
        val screen = createSourcePreferenceScreen(source)
            ?: error("Mihon source does not expose configurable preferences")
        val preference = screen.findPreference<Preference>(key)
            ?: error("Mihon source preference is unavailable: $key")
        val accepted = when (preference) {
            is SwitchPreferenceCompat -> {
                val next = value as? Boolean
                    ?: error("Mihon switch preference requires a boolean")
                preference.callChangeListener(next).also { if (it) preference.isChecked = next }
            }
            is ListPreference -> {
                val next = value as? String
                    ?: error("Mihon list preference requires a string")
                require(preference.entryValues.orEmpty().any { it.toString() == next }) {
                    "Mihon list preference value is unavailable"
                }
                preference.callChangeListener(next).also { if (it) preference.value = next }
            }
            is MultiSelectListPreference -> {
                val next = value.asStringList("Mihon multi-select preference").toSet()
                preference.callChangeListener(next).also { if (it) preference.values = next }
            }
            is EditTextPreference -> {
                val next = value as? String
                    ?: error("Mihon text preference requires a string")
                preference.callChangeListener(next).also { if (it) preference.text = next }
            }
            else -> error("Mihon source preference type is unsupported")
        }
        require(accepted) { "Mihon source rejected the preference value" }
        return emptyMap()
    }

    private fun createSourcePreferenceScreen(source: Any): PreferenceGroup? {
        if (!source.hasMethod("setupPreferenceScreen", 1)) return null
        val sourceId = source.readValue("id", "getId")?.toString()
            ?: error("Mihon source id is missing")
        val manager = PreferenceManager(payloadContext).apply {
            sharedPreferencesName = "source_$sourceId"
        }
        val screen = manager.createPreferenceScreen(payloadContext)
        source.invokeHierarchyCompatible("setupPreferenceScreen", listOf(screen))
        return screen
    }

    private fun sourcePreferences(source: Any): SharedPreferences {
        val sourceId = source.readValue("id", "getId")?.toString()
            ?: error("Mihon source id is missing")
        return payloadContext.getSharedPreferences("source_$sourceId", Context.MODE_PRIVATE)
    }

    private fun enforceSourceRequestLimit(sourceId: String, source: Any) {
        val preferences = sourcePreferences(source)
        val permits = preferences.getInt(ZIC_REQUEST_LIMIT_KEY, 0)
        if (permits <= 0) return
        val periodMillis = preferences.getInt(ZIC_REQUEST_PERIOD_KEY, 60)
            .coerceIn(1, 3600) * 1000L
        rateLimiters.getOrPut(sourceId, ::SourceRequestLimiter)
            .acquire(permits.coerceAtMost(1000), periodMillis)
    }

    private fun mihonPageResource(source: Any, page: Any, index: Int): JSONObject {
        val imageUrl = page.readString("imageUrl", "getImageUrl")
        if (shouldDeferMihonPageImage(imageUrl)) {
            return JSONObject()
                .put("deferredPage", true)
                .put("index", page.readLong("index", "getIndex")?.toInt() ?: index)
                .put("pageUrl", page.readString("url", "getUrl").orEmpty())
        }
        return resolvedMihonPageResource(source, page, requireNotNull(imageUrl))
    }

    private fun resolveDeferredMihonPageResource(source: Any, resource: JSONObject): JSONObject {
        val page = createPageModel(
            source.javaClass.classLoader,
            resource.optInt("index"),
            resource.optString("pageUrl"),
            null,
        )
        val imageUrl = try {
            source.invokeFirst(
                listOf(
                    Invocation("getImageUrl", listOf(page)),
                    Invocation("fetchImageUrl", listOf(page)),
                ),
            ).unwrapAsync() as? String
        } catch (_: NoSuchMethodException) {
            resource.optString("pageUrl")
                .takeIf { it.startsWith("http://") || it.startsWith("https://") }
        }?.takeIf { it.isNotBlank() }
            ?: error("Mihon page did not expose an image URL")
        page.writeValue("imageUrl", imageUrl)
        return resolvedMihonPageResource(source, page, imageUrl)
    }

    private fun resolvedMihonPageResource(
        source: Any,
        page: Any,
        imageUrl: String,
    ): JSONObject {
        val imageRequest = try {
            source.invokeHierarchyCompatible("imageRequest", listOf(page))
        } catch (_: NoSuchMethodException) {
            null
        }
        val requestUrl = imageRequest?.readValue("url", "getUrl")?.toString()
            ?.takeIf { it.startsWith("http://") || it.startsWith("https://") }
            ?: imageUrl.takeIf { it.startsWith("http://") || it.startsWith("https://") }
            ?: error("Mihon image request did not expose an absolute URL")
        val requestHeaders = imageRequest?.readValue("headers", "getHeaders")
            ?: source.readValue("headers", "getHeaders")
        return JSONObject()
            .put("url", requestUrl)
            .put("headers", JSONObject(requestHeaders.stringHeaders()))
    }

    private fun loadResourceWithPlatformNetwork(
        uri: String,
        headers: Map<String, String>,
        requestId: String,
    ): ByteArray {
        val connection = URL(uri).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = true
        connection.connectTimeout = 5_000
        connection.readTimeout = 10_000
        connection.requestMethod = "GET"
        headers.forEach { (name, value) ->
            connection.setRequestProperty(name, value)
        }
        calls[requestId] = connection
        try {
            val code = connection.responseCode
            if (code !in 200..299) error("Mihon resource HTTP $code")
            val bytes = connection.inputStream.use { stream ->
                stream.readBytesBounded(maxResponseBytes)
            }
            ensureNotCancelled(requestId)
            return bytes
        } finally {
            calls.remove(requestId)
            connection.disconnect()
        }
    }

    private fun mangaSummary(source: Any, manga: Any): Map<String, Any?> {
        val id = encodeOpaque("manga", mihonModelJson(manga))
        val title = manga.readString("title", "getTitle")?.ifBlank { null } ?: "未命名漫画"
        val author = manga.readString("author", "getAuthor")
        val artist = manga.readString("artist", "getArtist")
        return mutableMapOf<String, Any?>(
            "comicId" to id,
            "title" to title,
            "authors" to listOfNotNull(author, artist).distinct(),
            "tags" to mihonGenres(manga),
            "contentRating" to "suggestive",
        ).apply {
            mihonCoverResource(source, manga)?.let { put("coverUri", it) }
            manga.readString("description", "getDescription")
                ?.takeIf { it.isNotBlank() }
                ?.let { put("description", it) }
        }
    }

    private fun comicMessage(source: Any, manga: Any, comicId: String): Map<String, Any?> =
        mutableMapOf<String, Any?>(
            "comicId" to comicId,
            "title" to (manga.readString("title", "getTitle")?.ifBlank { null } ?: "未命名漫画"),
            "authors" to listOfNotNull(
                manga.readString("author", "getAuthor"),
                manga.readString("artist", "getArtist"),
            ).distinct(),
            "tags" to mihonGenres(manga),
            "readingDirection" to "vertical",
        ).apply {
            mihonCoverResource(source, manga)?.let { put("coverUri", it) }
            manga.readString("description", "getDescription")
                ?.takeIf { it.isNotBlank() }
                ?.let { put("description", it) }
        }

    private fun mihonCoverResource(source: Any, manga: Any): String? {
        val raw = manga.readString("thumbnail_url", "getThumbnail_url", "getThumbnailUrl")
            ?.trim()
            ?.takeIf(String::isNotEmpty)
            ?: return null
        val baseUrl = source.readString("baseUrl", "getBaseUrl")?.trim().orEmpty()
        val absolute = runCatching {
            when {
                raw.startsWith("https://") || raw.startsWith("http://") -> raw
                raw.startsWith("//") -> {
                    val scheme = runCatching { URL(baseUrl).protocol }.getOrDefault("https")
                    "$scheme:$raw"
                }
                baseUrl.isNotBlank() -> URL(URL(baseUrl), raw).toString()
                else -> return null
            }
        }.getOrNull() ?: return null
        val headers = source.readValue("headers", "getHeaders").stringHeaders()
        val resource = JSONObject().put("url", absolute)
        if (headers.isNotEmpty()) {
            resource.put("headers", JSONObject(headers))
        }
        return encodeOpaque("resource", resource)
    }

    private fun chapterMessage(
        chapter: Any,
        comicId: String,
        sequence: Int,
        synthetic: Boolean = false,
        pageCount: Int? = null,
        transportRevision: String? = null,
    ): Map<String, Any?> {
        val json = mihonModelJson(chapter).apply {
            put("comicId", comicId)
            put("sequence", sequence)
            if (synthetic) {
                put("synthetic", true)
                put("synthetic_revision", MIHON_SYNTHETIC_REVISION)
            }
        }
        val id = encodeOpaque("chapter", json)
        val title = chapter.readString("name", "getName")?.ifBlank { null }
            ?: "第 ${sequence + 1} 话"
        return mutableMapOf<String, Any?>(
            "comicId" to comicId,
            "chapterId" to id,
            "title" to title,
            "sequence" to sequence,
            "pageCount" to (pageCount ?: 0),
            "sourceRevision" to listOfNotNull(
                chapter.readString("url", "getUrl")?.takeIf { it.isNotBlank() },
                chapter.readLong("date_upload", "getDate_upload", "getDateUpload")?.toString(),
                transportRevision,
            ).joinToString(":"),
        ).apply {
            val published = chapter.readLong("date_upload", "getDate_upload", "getDateUpload")
            if (published != null && published > 0) {
                put("publishedAt", formatInstant(published))
            }
        }
    }

    private fun ensureNotCancelled(requestId: String) {
        if (cancelled.contains(requestId) || Thread.currentThread().isInterrupted) {
            throw InterruptedException("request cancelled")
        }
    }

    companion object {
        fun create(
            context: Context,
            driverId: String,
            activation: Map<String, Any?>,
            payloadPath: String,
            payloadLength: Long,
            payloadSha256: String,
            executor: ExecutorService,
        ): MihonRuntimeDriver {
            val payload = File(payloadPath)
            verifyPayload(payload, payloadLength, payloadSha256)
            verifyMihonCommonRuntimeAbi(context.classLoader)
            val pluginId = activation.requireString("pluginId")
            val version = activation.requireString("pluginVersion")
            val extensionLib = activation.requireString("extensionLib")
            require(extensionLib in supportedMihonExtensionLibs) {
                "Unsupported Mihon extension ABI: $extensionLib"
            }
            val runtimeRoot = mihonRuntimeRoot(
                codeCacheDir = context.codeCacheDir,
                pluginId = pluginId,
                version = version,
                driverId = driverId,
            ).apply {
                deleteRecursively()
                check(mkdirs()) { "Mihon runtime directory could not be created" }
            }
            try {
                val apk = stageReadOnlyMihonApk(
                    payload = payload,
                    target = File(runtimeRoot, "extension.apk"),
                    expectedLength = payloadLength,
                    expectedSha256 = payloadSha256,
                )
                val abi = stageReadOnlyMihonAbi(
                    context = context,
                    extensionLib = extensionLib,
                    target = File(runtimeRoot, "abi.jar"),
                )
                val nativeDir = extractNativeLibraries(apk, File(runtimeRoot, "lib"))
                val abiOptimized = File(runtimeRoot, "abi-dex").apply {
                    check(mkdirs()) { "Mihon ABI dex directory could not be created" }
                }
                val abiLoader = DexClassLoader(
                    abi.path,
                    abiOptimized.path,
                    null,
                    context.classLoader,
                )
                val extensionOptimized = File(runtimeRoot, "extension-dex").apply {
                    check(mkdirs()) { "Mihon extension dex directory could not be created" }
                }
                val loader = MihonExtensionClassLoader(
                    dexPath = apk.path,
                    optimizedDirectory = extensionOptimized,
                    librarySearchPath = nativeDir,
                    parent = abiLoader,
                )
                verifyMihonPluginAbi(loader)
                val extensionContext = createMihonPayloadContext(
                    base = context,
                    apk = apk,
                    loader = loader,
                    expectedPackageName = activation.requireString("packageName"),
                    runtimeRoot = runtimeRoot,
                )
                try {
                    initializeMihonInjekt(loader, extensionContext)
                } catch (error: Throwable) {
                    throw IllegalStateException(
                        "Mihon Injekt initialization failed: ${error.sanitizedMessage()}",
                        error,
                    )
                }
                val limits = activation["limits"].stringMap("runtime limits")
                val maxResponseBytes = limits.requireLong("maxResponseBytes")
                    .coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                val entries = activation["entryClasses"].asStringList("entryClasses")
                require(entries.isNotEmpty()) { "Mihon extension declares no entry classes" }
                val discovered = LinkedHashMap<String, Any>()
                entries.forEach { className ->
                    try {
                        val entry = instantiateMihonEntry(loader.loadClass(className), extensionContext)
                        val candidates = when {
                            entry.hasMethod("createSources", 0) ->
                                entry.invokeCompatible("createSources", emptyList()).asObjectList()
                            else -> listOf(entry)
                        }
                        require(candidates.isNotEmpty()) {
                            "Mihon entry exposed no sources"
                        }
                        candidates.forEach { source ->
                            val id = source.readValue("id", "getId")?.toString()
                                ?: error("Mihon source id is missing")
                            require(discovered.putIfAbsent(id, source) == null) {
                                "Mihon extension exposed duplicate source id: $id"
                            }
                        }
                    } catch (error: Throwable) {
                        throw IllegalStateException(
                            "Mihon entry activation failed: $className: " +
                                error.mihonDiagnosticMessage(),
                            error,
                        )
                    }
                }
                require(discovered.isNotEmpty()) { "Mihon extension exposed no Source entries" }
                val descriptors = discovered.map { (id, source) ->
                    val baseUrl = source.readString("baseUrl", "getBaseUrl")
                        ?: runCatching { source.invokeOptional("getHomeUrl") as? String }.getOrNull()
                        ?: "https://invalid.local/"
                    mapOf(
                        "externalId" to id,
                        "name" to normalizedMihonSourceName(
                            raw = source.readString("name", "getName"),
                            sourceId = id,
                            sourceType = source.javaClass.simpleName,
                            pluginId = pluginId,
                        ),
                        "language" to (source.readString("lang", "getLang") ?: "und"),
                        "website" to normalizeWebsite(baseUrl),
                        "supportsSearch" to true,
                        "browserUserAgent" to MIHON_BROWSER_USER_AGENT,
                        "contentRatings" to listOf("safe", "suggestive"),
                    )
                }
                return MihonRuntimeDriver(
                    driverId = driverId,
                    runtimeId = "mihon:$pluginId:$version",
                    executor = executor,
                    sourceById = ConcurrentHashMap(discovered),
                    chapterById = ConcurrentHashMap(),
                    chapterIdsByComic = ConcurrentHashMap(),
                    payloadContext = extensionContext,
                    runtimeRoot = runtimeRoot,
                    maxResponseBytes = maxResponseBytes,
                    sources = descriptors,
                )
            } catch (error: Throwable) {
                runtimeRoot.deleteRecursively()
                throw error
            }
        }
    }
}

private data class MihonComicCatalog(
    val manga: Any,
    val chapters: List<Any>,
    val chapterFailure: Throwable?,
    val chapterCatalogAvailable: Boolean,
)

internal data class MihonChapterSelection<T>(
    val chapters: List<T>,
    val synthetic: Boolean,
)

internal inline fun <T> selectMihonChapters(
    chapters: List<T>,
    allowSynthetic: Boolean = true,
    createSynthetic: () -> T,
): MihonChapterSelection<T> = if (chapters.isEmpty()) {
    if (allowSynthetic) {
        MihonChapterSelection(listOf(createSynthetic()), synthetic = true)
    } else {
        MihonChapterSelection(emptyList(), synthetic = false)
    }
} else {
    MihonChapterSelection(chapters, synthetic = false)
}

private const val MIHON_BROWSER_USER_AGENT =
    "Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 " +
        "Chrome/131 Mobile Safari/537.36"
private const val MAX_CACHED_MIHON_CHAPTERS = 4096
private const val MIHON_SYNTHETIC_REVISION = 3
private const val MIHON_RUNTIME_TRANSFORM_REVISION = "mihon-runtime-transform-v1"

internal fun mihonChapterMatches(chapter: Any, encoded: JSONObject): Boolean {
    val encodedUrl = encoded.optString("url").trim()
    val liveUrl = chapter.readString("url", "getUrl").orEmpty().trim()
    if (encodedUrl.isNotEmpty() && liveUrl.isNotEmpty()) return encodedUrl == liveUrl
    val encodedName = encoded.optString("name").trim()
    val liveName = chapter.readString("name", "getName").orEmpty().trim()
    val encodedNumber = encoded.optDouble("chapter_number", Double.NaN)
    val liveNumber = (chapter.readValue(
        "chapter_number",
        "getChapter_number",
        "getChapterNumber",
    ) as? Number)?.toDouble()
    val encodedScanlator = encoded.optString("scanlator").trim()
    val liveScanlator = chapter.readString("scanlator", "getScanlator").orEmpty().trim()
    val encodedDate = encoded.optLong("date_upload", Long.MIN_VALUE)
    val liveDate = chapter.readLong("date_upload", "getDate_upload", "getDateUpload")
    return encodedName.isNotEmpty() && encodedName == liveName &&
        (encodedNumber.isNaN() || liveNumber == null || encodedNumber == liveNumber) &&
        (encodedScanlator.isEmpty() || encodedScanlator == liveScanlator) &&
        (encodedDate == Long.MIN_VALUE || liveDate == null || encodedDate == liveDate)
}

private const val ZIC_REQUEST_LIMIT_KEY = "__zic_request_limit"
private const val ZIC_REQUEST_PERIOD_KEY = "__zic_request_period_seconds"
private val rateLimitedMihonOperations = setOf(
    "browse",
    "loadComic",
    "loadChapter",
    "loadResource",
)

private class SourceRequestLimiter {
    private val timestamps = ArrayDeque<Long>()
    private var currentPermits = 0
    private var currentPeriodMillis = 0L

    fun acquire(permits: Int, periodMillis: Long) {
        while (true) {
            val waitMillis = synchronized(this) {
                if (currentPermits != permits || currentPeriodMillis != periodMillis) {
                    timestamps.clear()
                    currentPermits = permits
                    currentPeriodMillis = periodMillis
                }
                val now = SystemClock.elapsedRealtime()
                while (timestamps.isNotEmpty() &&
                    timestamps.peekFirst() <= now - periodMillis
                ) {
                    timestamps.removeFirst()
                }
                if (timestamps.size < permits) {
                    timestamps.addLast(now)
                    return
                }
                (timestamps.peekFirst() + periodMillis - now).coerceAtLeast(1L)
            }
            Thread.sleep(waitMillis)
        }
    }
}

private fun PreferenceGroup.flattenPreferences(): Sequence<Preference> = sequence {
    for (index in 0 until preferenceCount) {
        val preference = getPreference(index)
        if (preference is PreferenceGroup) {
            yieldAll(preference.flattenPreferences())
        } else {
            yield(preference)
        }
    }
}

private fun preferenceMessage(preference: Preference): Map<String, Any?>? {
    val key = preference.key?.takeIf(String::isNotBlank) ?: return null
    val title = preference.title?.toString()?.takeIf(String::isNotBlank) ?: key
    val base = mutableMapOf<String, Any?>(
        "key" to key,
        "title" to title,
        "summary" to preference.summary?.toString()?.takeIf(String::isNotBlank),
        "sensitive" to preference.isSensitivePreference(),
        "choices" to emptyList<Map<String, String>>(),
    )
    when (preference) {
        is TwoStatePreference -> {
            base["kind"] = "toggle"
            base["value"] = preference.isChecked
        }
        is ListPreference -> {
            base["kind"] = "select"
            base["value"] = preference.value.orEmpty()
            base["choices"] = preference.entryValues.orEmpty().mapIndexed { index, value ->
                mapOf(
                    "value" to value.toString(),
                    "label" to (
                        preference.entries?.getOrNull(index)?.toString() ?: value.toString()
                    ),
                )
            }
        }
        is MultiSelectListPreference -> {
            base["kind"] = "multiSelect"
            base["value"] = preference.values.orEmpty().sorted()
            base["choices"] = preference.entryValues.orEmpty().mapIndexed { index, value ->
                mapOf(
                    "value" to value.toString(),
                    "label" to (
                        preference.entries?.getOrNull(index)?.toString() ?: value.toString()
                    ),
                )
            }
        }
        is EditTextPreference -> {
            base["kind"] = "text"
            base["value"] = preference.text.orEmpty()
        }
        else -> return null
    }
    return base
}

private fun Preference.isSensitivePreference(): Boolean {
    val identity = "${key.orEmpty()} ${title?.toString().orEmpty()}".lowercase()
    return listOf("password", "passwd", "token", "cookie", "secret", "密码", "令牌")
        .any(identity::contains)
}


@Suppress("DEPRECATION")
private fun createMihonPayloadContext(
    base: Context,
    apk: File,
    loader: ClassLoader,
    expectedPackageName: String,
    runtimeRoot: File,
): Context {
    val packageInfo = base.packageManager.getPackageArchiveInfo(
        apk.path,
        PackageManager.GET_META_DATA,
    ) ?: error("PackageManager rejected Mihon runtime APK")
    require(packageInfo.packageName == expectedPackageName) {
        "Mihon runtime package changed: ${packageInfo.packageName}"
    }
    val applicationInfo = requireNotNull(packageInfo.applicationInfo) {
        "Mihon runtime application metadata is missing"
    }.apply {
        sourceDir = apk.path
        publicSourceDir = apk.path
        nativeLibraryDir = File(runtimeRoot, "lib").path
    }
    val resources = base.packageManager.getResourcesForApplication(applicationInfo)
    return MihonPayloadContext(
        base = base,
        payloadPackageName = expectedPackageName,
        payloadApplicationInfo = applicationInfo,
        payloadResources = resources,
        payloadClassLoader = loader,
        storageRoot = File(runtimeRoot, "context").apply { mkdirs() },
    )
}

private class MihonPayloadContext(
    base: Context,
    private val payloadPackageName: String,
    private val payloadApplicationInfo: ApplicationInfo,
    private val payloadResources: Resources,
    private val payloadClassLoader: ClassLoader,
    private val storageRoot: File,
) : ContextWrapper(base) {
    private val isolatedName = safePath(payloadPackageName).take(24)
    private val isolatedTheme: Resources.Theme by lazy {
        payloadResources.newTheme().apply { runCatching { setTo(baseContext.theme) } }
    }

    override fun getApplicationContext(): Context = this
    override fun getPackageName(): String = payloadPackageName
    override fun getPackageCodePath(): String = payloadApplicationInfo.sourceDir
    override fun getPackageResourcePath(): String = payloadApplicationInfo.publicSourceDir
    override fun getApplicationInfo(): ApplicationInfo = payloadApplicationInfo
    override fun createPackageContext(packageName: String, flags: Int): Context =
        if (packageName == payloadPackageName) this else super.createPackageContext(packageName, flags)
    override fun getClassLoader(): ClassLoader = payloadClassLoader
    override fun getResources(): Resources = payloadResources
    override fun getAssets(): AssetManager = payloadResources.assets
    override fun getTheme(): Resources.Theme = isolatedTheme
    override fun getFilesDir(): File = File(storageRoot, "files").apply { mkdirs() }
    override fun getCacheDir(): File = File(storageRoot, "cache").apply { mkdirs() }
    override fun getCodeCacheDir(): File = File(storageRoot, "code-cache").apply { mkdirs() }
    override fun getNoBackupFilesDir(): File = File(storageRoot, "no-backup").apply { mkdirs() }

    override fun getSharedPreferences(name: String, mode: Int) =
        baseContext.getSharedPreferences("zic_mihon_${isolatedName}_$name", mode)

    override fun getSystemService(name: String): Any? =
        if (name == LAYOUT_INFLATER_SERVICE) {
            (baseContext.getSystemService(name) as? LayoutInflater)?.cloneInContext(this)
        } else {
            baseContext.getSystemService(name)
        }
}

internal val supportedMihonExtensionLibs: Set<String> = setOf("1.4", "1.5", "1.6")

internal fun mihonAbiAssetVersion(extensionLib: String): String = when (extensionLib) {
    "1.4" -> "1.4"
    // Keiyoushi publishes separate 1.4 and 1.6 API artifacts. The transitional
    // 1.5 metadata shape links against the compatible 1.6 API surface.
    "1.5", "1.6" -> "1.6"
    else -> error("Unsupported Mihon extension ABI: $extensionLib")
}

internal val requiredMihonPluginAbiClasses: List<String> = listOf(
    "eu.kanade.tachiyomi.source.Source",
    "eu.kanade.tachiyomi.source.SourceFactory",
    "eu.kanade.tachiyomi.source.online.HttpSource",
    "eu.kanade.tachiyomi.source.model.SManga",
    "eu.kanade.tachiyomi.source.model.SChapter",
    "eu.kanade.tachiyomi.source.model.Page",
    "eu.kanade.tachiyomi.network.NetworkHelper",
    "eu.kanade.tachiyomi.network.RequestsKt",
    "eu.kanade.tachiyomi.network.OkHttpExtensionsKt",
    "uy.kohesive.injekt.InjektKt",
    "uy.kohesive.injekt.api.TypeReference",
)

internal val requiredMihonCommonRuntimeClasses: List<String> = listOf(
    "androidx.preference.Preference",
    "kotlin.jvm.internal.Intrinsics",
    "okhttp3.OkHttpClient",
    "okio.Buffer",
    "rx.Observable",
    "rx.android.schedulers.AndroidSchedulers",
    "kotlinx.coroutines.CoroutineScope",
    "org.jsoup.Jsoup",
    "com.google.gson.Gson",
    "dev.zic.network.AndroidCloudflareInterceptor",
    "dev.zic.network.NetworkBrowserSnapshotStore",
    "dev.zic.network.AndroidBrowserCookieSession",
    "dev.zic.network.AndroidCookieJar",
    "dev.zic.network.FallbackDns",
)

internal fun missingMihonClasses(
    classLoader: ClassLoader,
    required: List<String>,
): List<String> = required.filter { className ->
    runCatching { classLoader.loadClass(className) }.isFailure
}

private fun verifyMihonCommonRuntimeAbi(classLoader: ClassLoader) {
    val missing = missingMihonClasses(classLoader, requiredMihonCommonRuntimeClasses)
    require(missing.isEmpty()) {
        "Mihon common runtime is incomplete: ${missing.joinToString()}"
    }
}

private fun verifyMihonPluginAbi(classLoader: ClassLoader) {
    val missing = missingMihonClasses(classLoader, requiredMihonPluginAbiClasses)
    require(missing.isEmpty()) {
        "Mihon ${classLoader.javaClass.simpleName} ABI is incomplete: ${missing.joinToString()}"
    }
}

private fun initializeMihonInjekt(
    classLoader: ClassLoader,
    context: Context,
) {
    runCatching { classLoader.loadClass("dev.mihon.injekt.InjektKt") }
        .getOrNull()
        ?.getMethod("patchInjekt")
        ?.invoke(null)

    val application = MihonPayloadApplication(context)
    val networkType = classLoader.loadClass("eu.kanade.tachiyomi.network.NetworkHelper")
    val network = networkType.getConstructor(Context::class.java).newInstance(application)
    val scope = classLoader.loadClass("uy.kohesive.injekt.InjektKt")
        .getMethod("getInjekt")
        .invoke(null)
    val typeReferenceType = classLoader.loadClass("uy.kohesive.injekt.api.TypeReference")
    mihonInjektSingletons(application, networkType, network).forEach { (type, value) ->
        val typeReference = Proxy.newProxyInstance(
            classLoader,
            arrayOf(typeReferenceType),
        ) { proxy, method, arguments ->
            when (method.name) {
                "getType" -> type
                "toString" -> "ZicMihonTypeReference(${type.name})"
                "hashCode" -> System.identityHashCode(proxy)
                "equals" -> arguments?.firstOrNull() === proxy
                else -> error("Unsupported Mihon Injekt TypeReference method: ${method.name}")
            }
        }
        scope.javaClass.methods.first {
            it.name == "addSingleton" && it.parameterCount == 2
        }.invoke(scope, typeReference, value)
    }
}

private class MihonPayloadApplication(base: Context) : Application() {
    init {
        attachBaseContext(base)
    }
}

internal fun mihonInjektSingletons(
    application: Application,
    networkType: Class<*>,
    network: Any,
): List<Pair<Class<*>, Any>> = listOf(
    Application::class.java to application,
    networkType to network,
)

internal fun isMihonParentFirstClass(name: String): Boolean {
    if (name.startsWith("eu.kanade.tachiyomi.extension.")) return false
    return name.startsWith("java.") ||
        name.startsWith("javax.") ||
        name.startsWith("android.") ||
        name.startsWith("androidx.") ||
        name.startsWith("kotlin.") ||
        name.startsWith("kotlinx.") ||
        name.startsWith("okhttp3.") ||
        name.startsWith("okio.") ||
        name.startsWith("rx.") ||
        name.startsWith("org.jsoup.") ||
        name.startsWith("org.json.") ||
        name.startsWith("com.google.gson.") ||
        name.startsWith("eu.kanade.tachiyomi.") ||
        name.startsWith("uy.kohesive.injekt.") ||
        name.startsWith("dev.mihon.injekt.") ||
        name.startsWith("dev.zic.network.")
}

private class MihonExtensionClassLoader(
    dexPath: String,
    optimizedDirectory: File,
    librarySearchPath: File?,
    parent: ClassLoader,
) : DexClassLoader(
    dexPath,
    optimizedDirectory.path,
    librarySearchPath?.path,
    parent,
) {
    override fun loadClass(name: String, resolve: Boolean): Class<*> {
        if (isMihonParentFirstClass(name)) return super.loadClass(name, resolve)
        synchronized(this) {
            val loaded = findLoadedClass(name) ?: runCatching { findClass(name) }
                .getOrElse { error ->
                    if (error !is ClassNotFoundException) throw error
                    super.loadClass(name, false)
                }
            if (resolve) resolveClass(loaded)
            return loaded
        }
    }
}

private data class MihonAbiAsset(
    val path: String,
    val length: Long,
    val sha256: String,
)

private fun readMihonAbiAsset(context: Context, extensionLib: String): MihonAbiAsset {
    val version = mihonAbiAssetVersion(extensionLib)
    val properties = Properties().apply {
        context.assets.open("mihon/abi/manifest.properties").use { input -> load(input) }
    }
    val prefix = "$version."
    val path = properties.getProperty(prefix + "file")
        ?.takeIf { it == "mihon/abi/$version/abi.jar" }
        ?: error("Mihon ABI manifest path is invalid for $version")
    val length = properties.getProperty(prefix + "length")?.toLongOrNull()
        ?.takeIf { it > 0 }
        ?: error("Mihon ABI manifest length is invalid for $version")
    val sha256 = properties.getProperty(prefix + "sha256")
        ?.lowercase()
        ?.takeIf { it.matches(Regex("[0-9a-f]{64}")) }
        ?: error("Mihon ABI manifest digest is invalid for $version")
    return MihonAbiAsset(path, length, sha256)
}

private fun stageReadOnlyMihonAbi(
    context: Context,
    extensionLib: String,
    target: File,
): File {
    val asset = readMihonAbiAsset(context, extensionLib)
    return stageReadOnlyMihonCode(
        target = target,
        expectedLength = asset.length,
        expectedSha256 = asset.sha256,
        label = "Mihon ${mihonAbiAssetVersion(extensionLib)} ABI",
    ) {
        context.assets.open(asset.path, AssetManager.ACCESS_STREAMING)
    }
}

private data class Invocation(val name: String, val args: List<Any?>)

private fun Any.invokeFirst(candidates: List<Invocation>): Any? {
    val failures = mutableListOf<Throwable>()
    for (candidate in candidates) {
        try {
            return invokeCompatible(candidate.name, candidate.args)
        } catch (error: NoSuchMethodException) {
            failures += error
        }
    }
    throw NoSuchMethodException(
        "none of ${candidates.joinToString { it.name }} are available on ${javaClass.name}",
    ).also { failure -> failures.forEach(failure::addSuppressed) }
}

private fun Any.invokeCompatible(name: String, args: List<Any?>): Any? {
    val methods = javaClass.methods.filter { method ->
        method.name == name &&
            (method.parameterCount == args.size ||
                (method.parameterCount == args.size + 1 &&
                    Continuation::class.java.isAssignableFrom(method.parameterTypes.last())))
    }
    val method = methods.firstOrNull { it.accepts(args) }
        ?: throw NoSuchMethodException("${javaClass.name}.$name/${args.size}")
    method.isAccessible = true
    return if (method.parameterCount == args.size + 1) {
        invokeSuspend(this, method, args)
    } else {
        method.invoke(this, *args.toTypedArray())
    }
}

private fun Any.invokeMihonCompatible(name: String, args: List<Any?>): Any? =
    try {
        invokeCompatible(name, args)
    } catch (_: NoSuchMethodException) {
        invokeHierarchyCompatible(name, args)
    }

private fun Any.invokeHierarchyCompatible(name: String, args: List<Any?>): Any? {
    var current: Class<*>? = javaClass
    while (current != null) {
        val method = current.declaredMethods.firstOrNull {
            it.name == name &&
                (it.parameterCount == args.size ||
                    (it.parameterCount == args.size + 1 &&
                        Continuation::class.java.isAssignableFrom(it.parameterTypes.last()))) &&
                it.accepts(args)
        }
        if (method != null) {
            method.isAccessible = true
            return if (method.parameterCount == args.size + 1) {
                invokeSuspend(this, method, args)
            } else {
                method.invoke(this, *args.toTypedArray())
            }
        }
        current = current.superclass
    }
    throw NoSuchMethodException("${javaClass.name}.$name/${args.size}")
}

private fun Method.accepts(args: List<Any?>): Boolean {
    val types = parameterTypes.take(args.size)
    return types.indices.all { index ->
        val argument = args[index]
        argument == null || types[index].boxed().isAssignableFrom(argument.javaClass)
    }
}

private fun Class<*>.boxed(): Class<*> = when (this) {
    java.lang.Integer.TYPE -> Integer::class.java
    java.lang.Long.TYPE -> java.lang.Long::class.java
    java.lang.Boolean.TYPE -> java.lang.Boolean::class.java
    java.lang.Double.TYPE -> java.lang.Double::class.java
    java.lang.Float.TYPE -> java.lang.Float::class.java
    else -> this
}

private fun invokeSuspend(receiver: Any, method: Method, args: List<Any?>): Any? {
    val latch = CountDownLatch(1)
    var completed: Result<Any?>? = null
    val continuation = object : Continuation<Any?> {
        override val context: CoroutineContext = EmptyCoroutineContext
        override fun resumeWith(result: Result<Any?>) {
            completed = result
            latch.countDown()
        }
    }
    val immediate = method.invoke(receiver, *(args + continuation).toTypedArray())
    if (immediate !== kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED) return immediate
    while (!latch.await(250, TimeUnit.MILLISECONDS)) {
        if (Thread.currentThread().isInterrupted) throw InterruptedException("suspend call cancelled")
    }
    return completed!!.getOrThrow()
}

private fun Any?.unwrapAsync(): Any {
    var value = this ?: error("Mihon operation returned no value")
    repeat(6) {
        val current = value
        if (current is Future<*>) {
            value = current.get() ?: error("Mihon future returned no value")
            return@repeat
        }
        val directBlocking = current.javaClass.methods.firstOrNull { method ->
            method.parameterCount == 0 && method.name in setOf(
                "blockingGet",
                "blockingFirst",
                "blockingSingle",
            )
        }
        if (directBlocking != null) {
            value = directBlocking.invoke(current)
                ?: error("Mihon reactive operation returned no value")
            return@repeat
        }
        val toBlocking = current.javaClass.methods.firstOrNull {
            it.name == "toBlocking" && it.parameterCount == 0
        }
        if (toBlocking != null) {
            val blocking = toBlocking.invoke(current)
            val terminal = blocking.javaClass.methods.firstOrNull { method ->
                method.parameterCount == 0 && method.name in setOf(
                    "single",
                    "value",
                    "first",
                )
            } ?: error(
                "Mihon reactive type ${current.javaClass.name} has no supported blocking terminal",
            )
            value = terminal.invoke(blocking)
                ?: error("Mihon reactive operation returned no value")
            return@repeat
        }
        return current
    }
    return value
}

private fun Any?.asObjectList(): List<Any> = when (this) {
    null -> emptyList()
    is Iterable<*> -> filterNotNull()
    is Array<*> -> filterNotNull()
    else -> readList("items", "getItems")
}

private fun Any.readList(vararg names: String): List<Any> {
    val value = readValue(*names)
    return when (value) {
        null -> emptyList()
        is Iterable<*> -> value.filterNotNull()
        is Array<*> -> value.filterNotNull()
        else -> error("${javaClass.name}.${names.first()} is not a list")
    }
}

private fun Any.readValue(vararg names: String): Any? {
    for (name in names) {
        javaClass.methods.firstOrNull { it.name == name && it.parameterCount == 0 }?.let {
            return it.invoke(this)
        }
        runCatching { javaClass.getField(name) }.getOrNull()?.let { return it.get(this) }
        runCatching { javaClass.getDeclaredField(name) }.getOrNull()?.let {
            it.isAccessible = true
            return it.get(this)
        }
    }
    return null
}

internal fun normalizedMihonSourceName(
    raw: String?,
    sourceId: String,
    sourceType: String,
    pluginId: String,
): String {
    val value = raw?.trim().orEmpty()
    val numericIdentity = Regex("^(?:mihon:)?-?\\d+$")
    if (value.isNotEmpty() && value != sourceId && !numericIdentity.matches(value)) {
        return value
    }
    val typeName = sourceType
        .removeSuffix("HttpSource")
        .removeSuffix("Source")
        .trim()
    if (typeName.isNotEmpty() && typeName !in setOf("Source", "Http")) {
        return typeName
    }
    val pluginName = pluginId.substringAfterLast('.').substringAfterLast(':').trim()
    return pluginName.takeIf { it.isNotEmpty() } ?: "Mihon"
}

internal fun mihonSourceRequiresRuntimeTransform(source: Any): Boolean {
    val sourceLoader = source.javaClass.classLoader ?: return false
    val client = source.readValue("client", "getClient") ?: return false
    val capabilities = buildList {
        for (name in listOf(
            "interceptors", "getInterceptors",
            "networkInterceptors", "getNetworkInterceptors",
        )) {
            when (val value = client.invokeOptional(name)) {
                is Iterable<*> -> addAll(value.filterNotNull())
                is Array<*> -> addAll(value.filterNotNull())
            }
        }
        for (name in listOf(
            "cookieJar", "getCookieJar",
            "authenticator", "getAuthenticator",
            "proxyAuthenticator", "getProxyAuthenticator",
            "dns", "getDns",
        )) {
            client.invokeOptional(name)?.let(::add)
        }
    }
    return capabilities.any { capability ->
        capability.javaClass.classLoader === sourceLoader
    }
}

private fun mihonGenres(manga: Any): List<String> {
    val direct = runCatching {
        manga.readList("genres", "getGenres").map { it.toString() }
    }.getOrDefault(emptyList())
    val raw = manga.readString("genre", "getGenre")
        ?.split(',', ';', '\n')
        .orEmpty()
    return (direct + raw)
        .map(String::trim)
        .filter(String::isNotEmpty)
        .distinctBy { it.lowercase(Locale.US) }
}

private fun Throwable.isMihonCapabilityAbsence(): Boolean {
    val cause = rootCause()
    if (this is NoSuchMethodException || cause is NoSuchMethodException ||
        cause is AbstractMethodError
    ) {
        return true
    }
    if (cause !is UnsupportedOperationException) {
        return false
    }
    // Mihon 1.6 compatibility interfaces and HttpSource defaults use an
    // UnsupportedOperationException for genuinely absent legacy methods. An
    // extension parser can also throw the same type for a real source/network
    // failure; treating every UOE as capability absence enabled a false
    // synthetic single chapter after Cloudflare failures. Only accept UOE
    // frames owned by the shared Mihon ABI defaults.
    return cause.stackTrace.any { frame ->
        frame.className == "eu.kanade.tachiyomi.source.Source" ||
            frame.className.startsWith("eu.kanade.tachiyomi.source.Source\$") ||
            frame.className == "eu.kanade.tachiyomi.source.CatalogueSource" ||
            frame.className.startsWith("eu.kanade.tachiyomi.source.CatalogueSource\$") ||
            frame.className == "eu.kanade.tachiyomi.source.online.HttpSource"
    }
}

private fun Any.readString(vararg names: String): String? = readValue(*names)?.toString()
private fun Any.readLong(vararg names: String): Long? = when (val value = readValue(*names)) {
    is Number -> value.toLong()
    else -> value?.toString()?.toLongOrNull()
}
private fun Any.readBoolean(vararg names: String): Boolean? = readValue(*names) as? Boolean

private fun Any?.stringHeaders(): Map<String, String> {
    if (this == null) return emptyMap()
    val names = invokeOptional("names") as? Set<*> ?: return emptyMap()
    return names.filterIsInstance<String>().mapNotNull { name ->
        (invokeOptional("get", name) as? String)?.let { name to it }
    }.toMap(LinkedHashMap())
}

private fun JSONObject?.stringMap(): Map<String, String> {
    if (this == null) return emptyMap()
    val result = LinkedHashMap<String, String>()
    keys().forEach { key -> optString(key).takeIf { it.isNotEmpty() }?.let { result[key] = it } }
    return result
}

private fun Any.invokeOptional(name: String, vararg args: Any?): Any? =
    runCatching { invokeCompatible(name, args.toList()) }.getOrNull()

private fun Any.hasMethod(name: String, parameters: Int): Boolean =
    javaClass.methods.any { it.name == name && it.parameterCount == parameters }

internal fun instantiateMihonEntry(type: Class<*>, context: Context): Any {
    require(!type.isInterface && !Modifier.isAbstract(type.modifiers)) {
        "Mihon entry class is not concrete: ${type.name}"
    }
    runCatching { type.getField("INSTANCE") }.getOrNull()?.let { field ->
        if (Modifier.isStatic(field.modifiers) && type.isAssignableFrom(field.type)) {
            return field.get(null) ?: error("Mihon Kotlin object INSTANCE is null: ${type.name}")
        }
    }
    val factories = type.methods.filter { method ->
        Modifier.isStatic(method.modifiers) &&
            method.name in setOf("create", "newInstance", "getInstance") &&
            type.isAssignableFrom(method.returnType)
    }
    factories.firstOrNull { method ->
        method.parameterCount == 1 &&
            method.parameterTypes[0].isAssignableFrom(context.javaClass)
    }?.let { method ->
        method.isAccessible = true
        return method.invoke(null, context)
            ?: error("Mihon entry factory returned null: ${type.name}.${method.name}")
    }
    factories.firstOrNull { it.parameterCount == 0 }?.let { method ->
        method.isAccessible = true
        return method.invoke(null)
            ?: error("Mihon entry factory returned null: ${type.name}.${method.name}")
    }
    type.declaredConstructors.firstOrNull { constructor ->
        constructor.parameterCount == 1 &&
            constructor.parameterTypes[0].isAssignableFrom(context.javaClass)
    }?.let { constructor ->
        constructor.isAccessible = true
        return constructor.newInstance(context)
    }
    val constructor = runCatching { type.getDeclaredConstructor() }.getOrElse {
        val signatures = type.declaredConstructors.joinToString { constructor ->
            constructor.parameterTypes.joinToString(prefix = "(", postfix = ")") { it.name }
        }
        throw IllegalArgumentException(
            "Mihon entry has no supported object, factory, Context or no-arg constructor: ${type.name} $signatures",
            it,
        )
    }
    constructor.isAccessible = true
    return constructor.newInstance()
}

private fun emptyFilterList(loader: ClassLoader): Any {
    val type = loader.loadClass("eu.kanade.tachiyomi.source.model.FilterList")
    type.constructors.firstOrNull { it.parameterCount == 0 }?.let { return it.newInstance() }
    type.constructors.firstOrNull { constructor ->
        constructor.parameterCount == 1 && constructor.parameterTypes[0].isArray
    }?.let { constructor ->
        val component = constructor.parameterTypes[0].componentType
        return constructor.newInstance(java.lang.reflect.Array.newInstance(component, 0))
    }
    return type.constructors.first().newInstance(emptyList<Any>())
}

private fun createModel(loader: ClassLoader, className: String, json: JSONObject): Any {
    val type = loader.loadClass(className)
    val staticFactory = type.methods.firstOrNull {
        Modifier.isStatic(it.modifiers) && it.name == "create" && it.parameterCount == 0
    }
    val companionFactory = runCatching {
        val companion = type.getField("Companion").get(null)
        companion.javaClass.methods.firstOrNull {
            it.name == "create" && it.parameterCount == 0
        }?.invoke(companion)
    }.getOrNull()
    val model = staticFactory?.invoke(null)
        ?: companionFactory
        ?: type.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
    json.keys().forEach { key ->
        if (key == "kind" || key == "comicId" || key == "sequence") return@forEach
        val value = json.opt(key)
        model.writeValue(key, value)
    }
    return model
}

private fun createPageModel(
    loader: ClassLoader,
    index: Int,
    url: String,
    imageUrl: String?,
): Any {
    val type = loader.loadClass("eu.kanade.tachiyomi.source.model.Page")
    val constructor = type.declaredConstructors.firstOrNull {
        it.parameterCount == 4 &&
            it.parameterTypes[0] == Integer.TYPE &&
            it.parameterTypes[1] == String::class.java &&
            it.parameterTypes[2] == String::class.java
    } ?: error("Mihon Page constructor is unavailable")
    constructor.isAccessible = true
    return constructor.newInstance(index, url, imageUrl, null)
}

private fun Any.writeValue(name: String, value: Any?) {
    val normalized = if (value === JSONObject.NULL) null else value
    val setter = "set" + name.split('_').joinToString("") {
        it.replaceFirstChar { char -> char.uppercase() }
    }
    val method = javaClass.methods.firstOrNull {
        it.name.equals(setter, ignoreCase = true) && it.parameterCount == 1
    }
    if (method != null) {
        val converted = normalized.convertFor(method.parameterTypes[0])
        runCatching { method.invoke(this, converted) }
        return
    }
    runCatching { javaClass.getDeclaredField(name) }.getOrNull()?.let { field ->
        field.isAccessible = true
        runCatching { field.set(this, normalized.convertFor(field.type)) }
    }
}

private fun Any?.convertFor(type: Class<*>): Any? = when {
    this == null -> null
    type == java.lang.Long.TYPE || type == java.lang.Long::class.java -> (this as? Number)?.toLong()
    type == java.lang.Integer.TYPE || type == Integer::class.java -> (this as? Number)?.toInt()
    type == java.lang.Boolean.TYPE || type == java.lang.Boolean::class.java -> this as? Boolean
    type.name == "kotlinx.serialization.json.JsonObject" && this is JSONObject ->
        runCatching {
            val jsonType = type.classLoader.loadClass("kotlinx.serialization.json.Json")
            val json = jsonType.getField("Default").get(null)
            jsonType.getMethod("parseToJsonElement", String::class.java)
                .invoke(json, toString())
        }.getOrNull()
    else -> this
}

internal fun shouldDeferMihonPageImage(imageUrl: String?): Boolean = imageUrl.isNullOrBlank()

internal fun mihonModelJson(model: Any): JSONObject = JSONObject().apply {
    put("url", model.readString("url", "getUrl") ?: "")
    put("title", model.readString("title", "getTitle") ?: "")
    put("name", model.readString("name", "getName") ?: "")
    put("author", model.readString("author", "getAuthor") ?: "")
    put("artist", model.readString("artist", "getArtist") ?: "")
    put("description", model.readString("description", "getDescription") ?: "")
    put(
        "thumbnail_url",
        model.readString("thumbnail_url", "getThumbnail_url", "getThumbnailUrl") ?: "",
    )
    put("date_upload", model.readLong("date_upload", "getDate_upload", "getDateUpload") ?: 0L)
    put("chapter_number", model.readValue("chapter_number", "getChapter_number", "getChapterNumber") ?: -1f)
    put("scanlator", model.readString("scanlator", "getScanlator") ?: "")
    model.readValue("memo", "getMemo")?.toString()
        ?.takeIf { it.startsWith('{') && it.endsWith('}') }
        ?.let { memo -> runCatching { put("memo", JSONObject(memo)) } }
}

private fun encodeOpaque(kind: String, json: JSONObject): String {
    json.put("kind", kind)
    val encoded = android.util.Base64.encodeToString(
        json.toString().toByteArray(Charsets.UTF_8),
        android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING,
    )
    return "mihon:$kind:$encoded"
}

private fun decodeOpaque(value: String, expectedKind: String): JSONObject {
    val prefix = "mihon:$expectedKind:"
    require(value.startsWith(prefix)) { "invalid Mihon $expectedKind identity" }
    val decoded = android.util.Base64.decode(
        value.removePrefix(prefix),
        android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING,
    )
    return JSONObject(decoded.toString(Charsets.UTF_8)).also {
        require(it.optString("kind") == expectedKind) { "Mihon identity kind mismatch" }
    }
}

private fun Map<String, Any?>.nonNegativeInt(key: String): Int {
    val value = this[key] as? Number ?: error("$key is missing")
    return value.toInt().also { require(it >= 0) { "$key must be non-negative" } }
}

private fun Map<String, Any?>.positiveInt(key: String): Int =
    nonNegativeInt(key).also { require(it > 0) { "$key must be positive" } }

private fun Any?.asStringList(label: String): List<String> {
    val list = this as? List<*> ?: error("$label must be a list")
    return list.map { value ->
        (value as? String)?.takeIf { it.isNotBlank() } ?: error("$label contains an invalid value")
    }
}

private fun stageReadOnlyMihonApk(
    payload: File,
    target: File,
    expectedLength: Long,
    expectedSha256: String,
): File = stageReadOnlyMihonCode(
    target = target,
    expectedLength = expectedLength,
    expectedSha256 = expectedSha256,
    label = "Mihon runtime APK",
) { payload.inputStream().buffered() }

private fun stageReadOnlyMihonCode(
    target: File,
    expectedLength: Long,
    expectedSha256: String,
    label: String,
    openInput: () -> InputStream,
): File {
    target.parentFile?.let { parent ->
        check(parent.isDirectory || parent.mkdirs()) { "$label directory could not be created" }
    }
    val staging = File(target.parentFile, "${target.name}.part")
    if (staging.exists()) {
        check(staging.delete()) { "stale $label staging file could not be removed" }
    }
    FileOutputStream(staging).use { output ->
        check(staging.setReadOnly()) {
            "$label staging file could not be made read-only before writing"
        }
        openInput().use { input -> input.copyTo(output) }
        output.fd.sync()
    }
    verifyCodeFile(staging, expectedLength, expectedSha256, label)
    if (target.exists()) check(target.delete()) { "$label could not be replaced" }
    check(staging.renameTo(target)) { "$label staging file could not be promoted" }
    check(target.setReadOnly()) { "$label could not remain read-only" }
    verifyCodeFile(target, expectedLength, expectedSha256, label)
    return target
}

private fun verifyPayload(file: File, expectedLength: Long, expectedSha256: String) {
    verifyCodeFile(file, expectedLength, expectedSha256, "plugin payload")
}

private fun verifyCodeFile(
    file: File,
    expectedLength: Long,
    expectedSha256: String,
    label: String,
) {
    require(file.isFile) { "$label is missing" }
    require(file.length() == expectedLength) { "$label length changed" }
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().buffered().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
    }
    val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    require(actual.equals(expectedSha256, ignoreCase = true)) { "$label digest changed" }
}

private fun extractNativeLibraries(apk: File, root: File): File? {
    ZipFile(apk).use { zip ->
        val abi = Build.SUPPORTED_ABIS.firstOrNull { candidate ->
            zip.entries().asSequence().any { entry ->
                entry.name.startsWith("lib/$candidate/") && entry.name.endsWith(".so")
            }
        } ?: return null
        root.mkdirs()
        zip.entries().asSequence()
            .filter { !it.isDirectory && it.name.startsWith("lib/$abi/") && it.name.endsWith(".so") }
            .forEach { entry ->
                val target = File(root, File(entry.name).name)
                zip.getInputStream(entry).use { input ->
                    FileOutputStream(target).use { output -> input.copyTo(output) }
                }
            }
    }
    return root
}

private fun java.io.InputStream.readBytesBounded(maxBytes: Int): ByteArray {
    val output = java.io.ByteArrayOutputStream(minOf(maxBytes, 64 * 1024))
    val buffer = ByteArray(16 * 1024)
    var total = 0
    while (true) {
        val count = read(buffer)
        if (count < 0) break
        total += count
        require(total <= maxBytes) { "response exceeds runtime limit" }
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}

private fun normalizeWebsite(value: String): String = runCatching {
    val uri = android.net.Uri.parse(value)
    if (uri.scheme == "http" || uri.scheme == "https") value else "https://invalid.local/"
}.getOrDefault("https://invalid.local/")

internal fun cleanupStaleMihonRuntimeRoots(codeCacheDir: File) {
    File(codeCacheDir, "mihon").deleteRecursively()
}

internal fun mihonRuntimeRoot(
    codeCacheDir: File,
    pluginId: String,
    version: String,
    driverId: String,
): File = File(
    codeCacheDir,
    "mihon/${safePath(pluginId)}/${safePath(version)}/${safePath(driverId)}",
)

private fun safePath(value: String): String =
    MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }

private fun Throwable.rootCause(): Throwable {
    var current = this
    while (current.cause != null && current.cause !== current) current = current.cause!!
    return current
}

private fun Throwable.mihonDiagnosticMessage(): String {
    val parts = mutableListOf<String>()
    var current: Throwable? = this
    val visited = java.util.Collections.newSetFromMap(
        java.util.IdentityHashMap<Throwable, Boolean>(),
    )
    while (current != null && visited.add(current) && parts.size < 4) {
        val message = current.message?.takeIf(String::isNotBlank)
        val part = if (message == null) {
            current.javaClass.simpleName
        } else {
            "${current.javaClass.simpleName}: $message"
        }
        if (parts.lastOrNull() != part) parts += part
        current = current.cause
    }
    val frames = generateSequence(this as Throwable?) { it.cause }
        .flatMap { it.stackTrace.asSequence() }
        .toList()
    val frame = frames.firstOrNull {
        it.className.startsWith("eu.kanade.tachiyomi.extension.")
    } ?: frames.firstOrNull {
        !it.className.startsWith("dev.zic.pluginhost.") &&
            !it.className.startsWith("java.lang.reflect.") &&
            !it.className.startsWith("kotlin.reflect.")
    }
    val location = frame?.let {
        " at ${it.className}.${it.methodName}" +
            if (it.lineNumber > 0) ":${it.lineNumber}" else ""
    }.orEmpty()
    return (parts.joinToString(" <- ") + location).take(600)
}

private fun Throwable.isSourceVerificationFailure(): Boolean {
    var current: Throwable? = this
    val visited = java.util.Collections.newSetFromMap(
        java.util.IdentityHashMap<Throwable, Boolean>(),
    )
    while (current != null && visited.add(current)) {
        val message = current.message.orEmpty().lowercase(Locale.US)
        if (message.contains("cloudflare verification failed") ||
            message.contains("source verification required") ||
            message.contains("cf-mitigated")) {
            return true
        }
        current = current.cause
    }
    return false
}

private fun Throwable.isNetworkFailure(): Boolean =
    this is java.io.IOException || javaClass.name.contains("Http", ignoreCase = true)

private fun formatInstant(epochMillis: Long): String {
    val formatter = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", java.util.Locale.US)
    formatter.timeZone = java.util.TimeZone.getTimeZone("UTC")
    return formatter.format(java.util.Date(epochMillis))
}
