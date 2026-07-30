package dev.zic.pluginhost

import android.content.Context
import android.os.Build
import dalvik.system.DexClassLoader
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.lang.reflect.Method
import java.lang.reflect.Modifier
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
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
    private val context: Context,
    override val driverId: String,
    override val runtimeId: String,
    private val executor: ExecutorService,
    private val sourceById: Map<String, Any>,
    private val maxResponseBytes: Int,
    override val sources: List<Map<String, Any?>>,
) : NativeExternalPluginDriver {
    private val cancelled = ConcurrentHashMap.newKeySet<String>()
    private val calls = ConcurrentHashMap<String, Any>()
    private val tasks = ConcurrentHashMap<String, Future<*>>()

    override fun invoke(request: Map<String, Any?>, result: NativeDriverResult) {
        val requestId = request.requireString("requestId")
        val sourceId = request.requireString("externalSourceId")
        val source = sourceById[sourceId]
        if (source == null) {
            result.error("source-missing", "Mihon source is not active")
            return
        }
        val task = executor.submit {
            try {
                ensureNotCancelled(requestId)
                val arguments = request["arguments"].stringMap("runtime request arguments")
                val payload = when (request.requireString("operation")) {
                    "browse" -> browse(source, arguments, requestId)
                    "loadComic" -> loadComic(source, arguments.requireString("comicId"), requestId)
                    "loadChapter" -> loadChapter(source, arguments.requireString("chapterId"), requestId)
                    "loadResource" -> loadResource(source, arguments.requireString("uri"), requestId)
                    else -> error("unsupported Mihon runtime operation")
                }
                ensureNotCancelled(requestId)
                result.success(payload)
            } catch (error: Throwable) {
                val cause = error.rootCause()
                val cancelledRequest = cancelled.contains(requestId) || cause is InterruptedException
                result.error(
                    if (cancelledRequest) "runtime-request-cancelled" else "mihon-operation-failed",
                    if (cancelledRequest) "Mihon request was cancelled" else cause.sanitizedMessage(),
                    retryable = !cancelledRequest && cause.isNetworkFailure(),
                )
            } finally {
                calls.remove(requestId)
                tasks.remove(requestId)
                cancelled.remove(requestId)
            }
        }
        tasks[requestId] = task
    }

    override fun cancel(requestId: String) {
        cancelled.add(requestId)
        when (val call = calls.remove(requestId)) {
            is HttpURLConnection -> call.disconnect()
            null -> Unit
            else -> call.invokeOptional("cancel")
        }
        tasks.remove(requestId)?.cancel(true)
    }

    override fun close() {
        tasks.keys.toList().forEach(::cancel)
        sourceById.values.distinctBy { System.identityHashCode(it) }.forEach { source ->
            runCatching { source.invokeOptional("close") }
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
            "items" to sliced.map { manga -> mangaSummary(manga) },
            "offset" to offset,
            "hasMore" to (hasNext || mangas.size > (offset % limit) + sliced.size),
        )
    }

    private fun loadComic(source: Any, comicId: String, requestId: String): Map<String, Any?> {
        val encoded = decodeOpaque(comicId, "manga")
        val manga = createModel(
            source.javaClass.classLoader,
            "eu.kanade.tachiyomi.source.model.SManga",
            encoded,
        )
        val update = try {
            source.invokeFirst(
                listOf(
                    Invocation("fetchMangaUpdate", listOf(manga, emptyList<Any>(), true, true)),
                ),
            ).unwrapAsync()
        } catch (_: NoSuchMethodException) {
            null
        }
        ensureNotCancelled(requestId)
        val detailedManga: Any
        val chapters: List<Any>
        if (update != null) {
            detailedManga = update.readValue("manga", "getManga") ?: manga
            chapters = update.readList("chapters", "getChapters")
        } else {
            detailedManga = source.invokeFirst(
                listOf(
                    Invocation("getMangaDetails", listOf(manga)),
                    Invocation("fetchMangaDetails", listOf(manga)),
                ),
            ).unwrapAsync()
            ensureNotCancelled(requestId)
            chapters = source.invokeFirst(
                listOf(
                    Invocation("getChapterList", listOf(detailedManga)),
                    Invocation("fetchChapterList", listOf(detailedManga)),
                ),
            ).unwrapAsync().asObjectList()
        }
        val chapterMessages = chapters.mapIndexed { index, chapter ->
            chapterMessage(chapter, comicId, index)
        }
        return mapOf(
            "comic" to comicMessage(detailedManga, comicId),
            "chapters" to chapterMessages,
        )
    }

    private fun loadChapter(source: Any, chapterId: String, requestId: String): Map<String, Any?> {
        val encoded = decodeOpaque(chapterId, "chapter")
        val comicId = encoded.optString("comicId")
        require(comicId.isNotBlank()) { "chapter comic identity is missing" }
        val chapter = createModel(
            source.javaClass.classLoader,
            "eu.kanade.tachiyomi.source.model.SChapter",
            encoded,
        )
        val pages = source.invokeFirst(
            listOf(
                Invocation("getPageList", listOf(chapter)),
                Invocation("fetchPageList", listOf(chapter)),
            ),
        ).unwrapAsync().asObjectList()
        ensureNotCancelled(requestId)
        val pageMessages = pages.mapIndexed { index, page ->
            var imageUrl = page.readString("imageUrl", "getImageUrl")
            if (imageUrl.isNullOrBlank()) {
                imageUrl = try {
                    source.invokeFirst(
                        listOf(
                            Invocation("getImageUrl", listOf(page)),
                            Invocation("fetchImageUrl", listOf(page)),
                        ),
                    ).unwrapAsync() as? String
                } catch (_: NoSuchMethodException) {
                    null
                }
            }
            val fallbackUrl = page.readString("url", "getUrl")
            val uri = imageUrl?.takeIf { it.isNotBlank() }
                ?: fallbackUrl?.takeIf { it.startsWith("http://") || it.startsWith("https://") }
                ?: error("Mihon page did not expose an image URL")
            mapOf(
                "chapterId" to chapterId,
                "pageId" to "${chapterId}:$index",
                "index" to index,
                "uri" to uri,
            )
        }
        return mapOf(
            "comicId" to comicId,
            "chapter" to chapterMessage(chapter, comicId, encoded.optInt("sequence", 0)),
            "pages" to pageMessages,
            "readingDirection" to "topToBottom",
        )
    }

    private fun loadResource(source: Any, uri: String, requestId: String): ByteArray {
        require(uri.startsWith("https://") || uri.startsWith("http://")) {
            "Mihon resource URI must use HTTP(S)"
        }
        val headers = source.readValue("headers", "getHeaders")
        val client = source.readValue("client", "getClient")
        if (client == null) {
            return loadResourceWithPlatformNetwork(uri, headers, requestId)
        }
        val loader = source.javaClass.classLoader
        val requestBuilderType = Class.forName("okhttp3.Request\$Builder", true, loader)
        val builder = requestBuilderType.getDeclaredConstructor().newInstance()
        builder.invokeCompatible("url", listOf(uri))
        headers?.let { value ->
            val names = value.invokeOptional("names") as? Set<*>
            names?.filterIsInstance<String>()?.forEach { name ->
                val headerValue = value.invokeOptional("get", name) as? String
                if (headerValue != null) {
                    builder.invokeCompatible("header", listOf(name, headerValue))
                }
            }
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

    private fun loadResourceWithPlatformNetwork(
        uri: String,
        headers: Any?,
        requestId: String,
    ): ByteArray {
        val connection = URL(uri).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = true
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        connection.requestMethod = "GET"
        headers?.let { value ->
            val names = value.invokeOptional("names") as? Set<*>
            names?.filterIsInstance<String>()?.forEach { name ->
                val headerValue = value.invokeOptional("get", name) as? String
                if (headerValue != null) {
                    connection.setRequestProperty(name, headerValue)
                }
            }
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

    private fun mangaSummary(manga: Any): Map<String, Any?> {
        val id = encodeOpaque("manga", modelJson(manga))
        val title = manga.readString("title", "getTitle")?.ifBlank { null } ?: "未命名漫画"
        val author = manga.readString("author", "getAuthor")
        val artist = manga.readString("artist", "getArtist")
        return mutableMapOf<String, Any?>(
            "comicId" to id,
            "title" to title,
            "authors" to listOfNotNull(author, artist).distinct(),
            "contentRating" to "suggestive",
        ).apply {
            manga.readString("thumbnail_url", "getThumbnail_url", "getThumbnailUrl")
                ?.takeIf { it.isNotBlank() }
                ?.let { put("coverUri", it) }
            manga.readString("description", "getDescription")
                ?.takeIf { it.isNotBlank() }
                ?.let { put("description", it) }
        }
    }

    private fun comicMessage(manga: Any, comicId: String): Map<String, Any?> =
        mutableMapOf<String, Any?>(
            "comicId" to comicId,
            "title" to (manga.readString("title", "getTitle")?.ifBlank { null } ?: "未命名漫画"),
            "authors" to listOfNotNull(
                manga.readString("author", "getAuthor"),
                manga.readString("artist", "getArtist"),
            ).distinct(),
            "readingDirection" to "topToBottom",
        ).apply {
            manga.readString("thumbnail_url", "getThumbnail_url", "getThumbnailUrl")
                ?.takeIf { it.isNotBlank() }
                ?.let { put("coverUri", it) }
            manga.readString("description", "getDescription")
                ?.takeIf { it.isNotBlank() }
                ?.let { put("description", it) }
        }

    private fun chapterMessage(chapter: Any, comicId: String, sequence: Int): Map<String, Any?> {
        val json = modelJson(chapter).apply {
            put("comicId", comicId)
            put("sequence", sequence)
        }
        val id = encodeOpaque("chapter", json)
        val title = chapter.readString("name", "getName")?.ifBlank { null }
            ?: "第 ${sequence + 1} 话"
        return mutableMapOf<String, Any?>(
            "comicId" to comicId,
            "chapterId" to id,
            "title" to title,
            "sequence" to sequence,
            "pageCount" to 0,
            "sourceRevision" to listOfNotNull(
                chapter.readString("url", "getUrl")?.takeIf { it.isNotBlank() },
                chapter.readLong("date_upload", "getDate_upload", "getDateUpload")?.toString(),
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
            val pluginId = activation.requireString("pluginId")
            val version = activation.requireString("pluginVersion")
            val runtimeRoot = File(context.codeCacheDir, "mihon/${safePath(pluginId)}/$version").apply {
                deleteRecursively()
                mkdirs()
            }
            val apk = File(runtimeRoot, "extension.apk")
            payload.copyTo(apk, overwrite = true)
            verifyPayload(apk, payloadLength, payloadSha256)
            val nativeDir = extractNativeLibraries(apk, File(runtimeRoot, "lib"))
            val optimized = File(runtimeRoot, "dex").apply { mkdirs() }
            val loader = DexClassLoader(
                apk.path,
                optimized.path,
                nativeDir?.path,
                context.classLoader,
            )
            val limits = activation["limits"].stringMap("runtime limits")
            val maxResponseBytes = limits.requireLong("maxResponseBytes")
                .coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
            val entries = activation["entryClasses"].asStringList("entryClasses")
            require(entries.isNotEmpty()) { "Mihon extension declares no entry classes" }
            val discovered = LinkedHashMap<String, Any>()
            entries.forEach { className ->
                val entry = instantiate(loader.loadClass(className), context)
                val candidates = when {
                    entry.hasMethod("createSources", 0) ->
                        entry.invokeCompatible("createSources", emptyList()).asObjectList()
                    else -> listOf(entry)
                }
                candidates.forEach { source ->
                    val id = source.readValue("id", "getId")?.toString()
                        ?: error("Mihon source id is missing")
                    discovered[id] = source
                }
            }
            require(discovered.isNotEmpty()) { "Mihon extension exposed no Source entries" }
            val descriptors = discovered.map { (id, source) ->
                val baseUrl = source.readString("baseUrl", "getBaseUrl")
                    ?: runCatching { source.invokeOptional("getHomeUrl") as? String }.getOrNull()
                    ?: "https://invalid.local/"
                mapOf(
                    "externalId" to id,
                    "name" to (source.readString("name", "getName") ?: "Mihon source"),
                    "language" to (source.readString("lang", "getLang") ?: "und"),
                    "website" to normalizeWebsite(baseUrl),
                    "supportsSearch" to true,
                    "contentRatings" to listOf("safe", "suggestive"),
                )
            }
            return MihonRuntimeDriver(
                context = context,
                driverId = driverId,
                runtimeId = "mihon:$pluginId:$version",
                executor = executor,
                sourceById = Collections.unmodifiableMap(discovered),
                maxResponseBytes = maxResponseBytes,
                sources = descriptors,
            )
        }
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
    if (value is Future<*>) value = value.get() ?: error("Mihon future returned no value")
    val toBlocking = value.javaClass.methods.firstOrNull {
        it.name == "toBlocking" && it.parameterCount == 0
    }
    if (toBlocking != null) {
        val blocking = toBlocking.invoke(value)
        value = blocking.javaClass.methods.first {
            it.name == "single" && it.parameterCount == 0
        }.invoke(blocking) ?: error("Mihon observable returned no value")
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

private fun Any.readString(vararg names: String): String? = readValue(*names)?.toString()
private fun Any.readLong(vararg names: String): Long? = when (val value = readValue(*names)) {
    is Number -> value.toLong()
    else -> value?.toString()?.toLongOrNull()
}
private fun Any.readBoolean(vararg names: String): Boolean? = readValue(*names) as? Boolean

private fun Any.invokeOptional(name: String, vararg args: Any?): Any? =
    runCatching { invokeCompatible(name, args.toList()) }.getOrNull()

private fun Any.hasMethod(name: String, parameters: Int): Boolean =
    javaClass.methods.any { it.name == name && it.parameterCount == parameters }

private fun instantiate(type: Class<*>, context: Context): Any {
    require(!type.isInterface && !Modifier.isAbstract(type.modifiers)) {
        "Mihon entry class is not concrete: ${type.name}"
    }
    type.declaredConstructors.firstOrNull { constructor ->
        constructor.parameterCount == 1 &&
            Context::class.java.isAssignableFrom(constructor.parameterTypes[0])
    }?.let { constructor ->
        constructor.isAccessible = true
        return constructor.newInstance(context)
    }
    val constructor = type.getDeclaredConstructor()
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
    else -> this
}

private fun modelJson(model: Any): JSONObject = JSONObject().apply {
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

private fun verifyPayload(file: File, expectedLength: Long, expectedSha256: String) {
    require(file.isFile) { "plugin payload is missing" }
    require(file.length() == expectedLength) { "plugin payload length changed" }
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
    require(actual.equals(expectedSha256, ignoreCase = true)) { "plugin payload digest changed" }
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

private fun safePath(value: String): String =
    android.util.Base64.encodeToString(
        value.toByteArray(Charsets.UTF_8),
        android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING,
    )

private fun Throwable.rootCause(): Throwable {
    var current = this
    while (current.cause != null && current.cause !== current) current = current.cause!!
    return current
}

private fun Throwable.isNetworkFailure(): Boolean =
    this is java.io.IOException || javaClass.name.contains("Http", ignoreCase = true)

private fun formatInstant(epochMillis: Long): String {
    val formatter = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", java.util.Locale.US)
    formatter.timeZone = java.util.TimeZone.getTimeZone("UTC")
    return formatter.format(java.util.Date(epochMillis))
}
