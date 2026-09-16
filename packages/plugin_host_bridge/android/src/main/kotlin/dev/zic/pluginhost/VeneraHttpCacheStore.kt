package dev.zic.pluginhost

import android.util.Log
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.net.URL
import java.security.MessageDigest
import java.util.Locale

private data class VeneraHttpCacheEntry(
    val requestHeaders: Map<String, String>,
    val response: VeneraHttpResponse,
    val storedAtNanos: Long,
    val storedAtEpochMillis: Long,
    val size: Int,
)

internal data class VeneraHttpCacheNamespace(
    val pluginId: String,
    val pluginVersion: String,
    val sourceKey: String,
)

private fun veneraCacheDebug(
    namespace: VeneraHttpCacheNamespace,
    url: String,
    state: String,
) {
    val enabled = runCatching {
        Log.isLoggable(VENERA_CACHE_LOG_TAG, Log.DEBUG)
    }.getOrDefault(false)
    if (!enabled) return
    val host = runCatching { URL(url).host }.getOrDefault("invalid")
    runCatching {
        Log.d(
            VENERA_CACHE_LOG_TAG,
            "venera-http-cache source=${namespace.sourceKey} host=$host state=$state",
        )
    }
}

private data class VeneraHttpCacheKey(
    val namespace: VeneraHttpCacheNamespace,
    val url: String,
)

internal class VeneraHttpCacheStore(
    private val persistentRoot: File? = null,
) {
    private val entries = LinkedHashMap<VeneraHttpCacheKey, VeneraHttpCacheEntry>()
    private var size = 0

    @Synchronized
    fun lookup(
        namespace: VeneraHttpCacheNamespace,
        url: String,
        requestHeaders: Map<String, String>,
        cacheTime: String?,
        nowNanos: Long = System.nanoTime(),
        forceMiss: Boolean = false,
        nowEpochMillis: Long = System.currentTimeMillis(),
    ): VeneraHttpResponse? {
        val key = VeneraHttpCacheKey(namespace, url)
        if (forceMiss) {
            veneraCacheDebug(namespace, url, "forced-miss")
            remove(key)
            removePersistent(namespace, url)
            return null
        }
        var entry = entries[key]
        if (entry == null && cacheTime.equals("long", ignoreCase = true)) {
            entry = loadPersistent(
                namespace = namespace,
                url = url,
                requestHeaders = requestHeaders,
                nowNanos = nowNanos,
                nowEpochMillis = nowEpochMillis,
            )
            if (entry != null) {
                putMemory(key, entry)
            }
        }
        if (entry == null) {
            veneraCacheDebug(namespace, url, "no-entry")
            return null
        }
        if (!veneraCacheHeadersMatch(requestHeaders, entry.requestHeaders)) {
            veneraCacheDebug(namespace, url, "request-header-mismatch")
            return null
        }
        if (cacheTime.equals("no", ignoreCase = true)) {
            veneraCacheDebug(namespace, url, "cache-time-no")
            remove(key)
            removePersistent(namespace, url)
            return null
        }
        val age = nowNanos - entry.storedAtNanos
        val fresh = if (cacheTime.equals("long", ignoreCase = true)) {
            age in 0 until VENERA_NETWORK_LONG_CACHE_NANOS
        } else {
            age in 0 until VENERA_NETWORK_SHORT_CACHE_NANOS
        }
        if (!fresh) {
            veneraCacheDebug(
                namespace,
                url,
                "stale ageMs=${age / 1_000_000L} cacheTime=${cacheTime ?: "default"}",
            )
            return null
        }
        veneraCacheDebug(namespace, url, "hit")
        entries.remove(key)
        entries[key] = entry
        if (cacheTime.equals("long", ignoreCase = true)) {
            val persistent = persistentFile(namespace, url)
            if (persistent != null && !persistent.isFile) {
                storePersistent(namespace, url, entry)
                trimPersistent(nowEpochMillis)
            }
        }
        touchPersistent(namespace, url, nowEpochMillis)
        return entry.response.withVeneraCacheHit()
    }

    @Synchronized
    fun staleForRevalidation(
        namespace: VeneraHttpCacheNamespace,
        url: String,
        requestHeaders: Map<String, String>,
        cacheTime: String?,
        nowNanos: Long = System.nanoTime(),
    ): VeneraHttpResponse? {
        if (cacheTime.equals("no", ignoreCase = true) ||
            cacheTime.equals("long", ignoreCase = true)
        ) {
            return null
        }
        val key = VeneraHttpCacheKey(namespace, url)
        val entry = entries[key] ?: return null
        if (!veneraCacheHeadersMatch(requestHeaders, entry.requestHeaders)) {
            return null
        }
        val age = nowNanos - entry.storedAtNanos
        if (age !in VENERA_NETWORK_SHORT_CACHE_NANOS until
            VENERA_NETWORK_REVALIDATION_NANOS
        ) {
            return null
        }
        entries.remove(key)
        entries[key] = entry
        return entry.response.copy(
            headers = JSONObject(entry.response.headers.toString()),
            body = entry.response.body.copyOf(),
        )
    }

    @Synchronized
    fun store(
        namespace: VeneraHttpCacheNamespace,
        url: String,
        requestHeaders: Map<String, String>,
        response: VeneraHttpResponse,
        nowNanos: Long = System.nanoTime(),
        cacheTime: String? = null,
        nowEpochMillis: Long = System.currentTimeMillis(),
    ) {
        val key = VeneraHttpCacheKey(namespace, url)
        if (veneraResponseDisallowsStorage(response.headers)) {
            veneraCacheDebug(namespace, url, "response-no-store")
            remove(key)
            removePersistent(namespace, url)
            return
        }
        if (response.status >= 400 ||
            response.body.isEmpty() ||
            response.body.size >= VENERA_NETWORK_MAX_CACHE_ENTRY_BYTES
        ) {
            return
        }
        remove(key)
        while (entries.isNotEmpty() &&
            size + response.body.size > VENERA_NETWORK_MAX_CACHE_BYTES
        ) {
            remove(entries.keys.first())
        }
        if (response.body.size > VENERA_NETWORK_MAX_CACHE_BYTES) return
        val entry = VeneraHttpCacheEntry(
            requestHeaders = LinkedHashMap(requestHeaders),
            response = response.copy(
                headers = JSONObject(response.headers.toString()),
                body = response.body.copyOf(),
            ),
            storedAtNanos = nowNanos,
            storedAtEpochMillis = nowEpochMillis,
            size = response.body.size,
        )
        putMemory(key, entry)
        if (cacheTime.equals("long", ignoreCase = true)) {
            storePersistent(namespace, url, entry)
            trimPersistent(nowEpochMillis)
        }
    }

    @Synchronized
    fun invalidate(namespace: VeneraHttpCacheNamespace, url: String) {
        remove(VeneraHttpCacheKey(namespace, url))
        removePersistent(namespace, url)
    }

    @Synchronized
    fun clearMemory() {
        entries.clear()
        size = 0
    }

    @Synchronized
    fun clear() {
        clearMemory()
        persistentRoot?.deleteRecursively()
    }

    private fun putMemory(key: VeneraHttpCacheKey, entry: VeneraHttpCacheEntry) {
        remove(key)
        while (entries.isNotEmpty() &&
            size + entry.size > VENERA_NETWORK_MAX_CACHE_BYTES
        ) {
            remove(entries.keys.first())
        }
        if (entry.size > VENERA_NETWORK_MAX_CACHE_BYTES) return
        entries[key] = entry
        size += entry.size
    }

    private fun remove(key: VeneraHttpCacheKey) {
        entries.remove(key)?.let { size -= it.size }
    }

    private fun persistentFile(
        namespace: VeneraHttpCacheNamespace,
        url: String,
    ): File? {
        val root = persistentRoot ?: return null
        val namespaceHash = veneraCacheHash(
            "${namespace.pluginId}\u0000${namespace.pluginVersion}\u0000${namespace.sourceKey}",
        )
        val urlHash = veneraCacheHash(url)
        return File(File(root, namespaceHash), "$urlHash.cache")
    }

    private fun loadPersistent(
        namespace: VeneraHttpCacheNamespace,
        url: String,
        requestHeaders: Map<String, String>,
        nowNanos: Long,
        nowEpochMillis: Long,
    ): VeneraHttpCacheEntry? {
        val file = persistentFile(namespace, url) ?: return null
        if (!file.isFile) return null
        val loaded = runCatching {
            DataInputStream(file.inputStream().buffered()).use { input ->
                require(input.readInt() == VENERA_PERSISTENT_CACHE_MAGIC)
                require(input.readInt() == VENERA_PERSISTENT_CACHE_VERSION)
                val storedAtEpochMillis = input.readLong()
                val status = input.readInt()
                val requestFingerprint = input.readUTF()
                val headerLength = input.readInt()
                val bodyLength = input.readInt()
                require(headerLength in 0..VENERA_PERSISTENT_CACHE_MAX_HEADER_BYTES)
                require(bodyLength in 1 until VENERA_NETWORK_MAX_CACHE_ENTRY_BYTES)
                val headerBytes = ByteArray(headerLength).also(input::readFully)
                val body = ByteArray(bodyLength).also(input::readFully)
                require(requestFingerprint == veneraRequestHeaderFingerprint(requestHeaders))
                val ageMillis = nowEpochMillis - storedAtEpochMillis
                require(ageMillis in 0 until VENERA_NETWORK_LONG_CACHE_MILLIS)
                val ageNanos = ageMillis * 1_000_000L
                VeneraHttpCacheEntry(
                    requestHeaders = LinkedHashMap(requestHeaders),
                    response = VeneraHttpResponse(
                        status = status,
                        headers = JSONObject(headerBytes.toString(Charsets.UTF_8)),
                        body = body,
                    ),
                    storedAtNanos = nowNanos - ageNanos,
                    storedAtEpochMillis = storedAtEpochMillis,
                    size = body.size,
                )
            }
        }.getOrNull()
        if (loaded == null) {
            file.delete()
            return null
        }
        file.setLastModified(nowEpochMillis)
        return loaded
    }

    private fun storePersistent(
        namespace: VeneraHttpCacheNamespace,
        url: String,
        entry: VeneraHttpCacheEntry,
    ) {
        val file = persistentFile(namespace, url) ?: return
        runCatching {
            file.parentFile?.mkdirs()
            val temp = File(file.parentFile, "${file.name}.part")
            val headerBytes = entry.response.headers.toString().toByteArray(Charsets.UTF_8)
            require(headerBytes.size <= VENERA_PERSISTENT_CACHE_MAX_HEADER_BYTES)
            DataOutputStream(temp.outputStream().buffered()).use { output ->
                output.writeInt(VENERA_PERSISTENT_CACHE_MAGIC)
                output.writeInt(VENERA_PERSISTENT_CACHE_VERSION)
                output.writeLong(entry.storedAtEpochMillis)
                output.writeInt(entry.response.status)
                output.writeUTF(veneraRequestHeaderFingerprint(entry.requestHeaders))
                output.writeInt(headerBytes.size)
                output.writeInt(entry.response.body.size)
                output.write(headerBytes)
                output.write(entry.response.body)
            }
            if (file.exists()) file.delete()
            if (!temp.renameTo(file)) {
                temp.delete()
                error("Venera persistent cache rename failed")
            }
            file.setLastModified(entry.storedAtEpochMillis)
        }
    }

    private fun removePersistent(namespace: VeneraHttpCacheNamespace, url: String) {
        persistentFile(namespace, url)?.delete()
    }

    private fun touchPersistent(
        namespace: VeneraHttpCacheNamespace,
        url: String,
        nowEpochMillis: Long,
    ) {
        persistentFile(namespace, url)?.takeIf(File::isFile)?.setLastModified(nowEpochMillis)
    }

    private fun trimPersistent(nowEpochMillis: Long) {
        val root = persistentRoot ?: return
        if (!root.isDirectory) return
        val files = root.walkTopDown()
            .filter { it.isFile && it.name.endsWith(".cache") }
            .toList()
            .sortedBy(File::lastModified)
        var total = files.sumOf(File::length)
        for (file in files) {
            val tooOld = nowEpochMillis - file.lastModified() >=
                VENERA_NETWORK_LONG_CACHE_MILLIS
            if (!tooOld && total <= VENERA_NETWORK_MAX_CACHE_BYTES) break
            val length = file.length()
            if (file.delete()) total -= length
        }
    }
}

private fun veneraCacheHash(value: String): String =
    MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }

private fun veneraRequestHeaderFingerprint(headers: Map<String, String>): String {
    val canonical = headers.entries
        .sortedBy { it.key.lowercase(Locale.US) }
        .joinToString("\u0000") {
            "${it.key.lowercase(Locale.US)}\u0001${it.value}"
        }
    return veneraCacheHash(canonical)
}

internal fun veneraCacheHeadersMatch(
    first: Map<String, String>,
    second: Map<String, String>,
): Boolean = veneraComparableRequestHeaders(first) ==
    veneraComparableRequestHeaders(second)

private fun veneraComparableRequestHeaders(
    headers: Map<String, String>,
): Map<String, String> = headers.entries.associate {
    it.key.lowercase(Locale.US) to it.value
}

internal fun veneraCacheResponseHeadersMatch(
    first: JSONObject,
    second: JSONObject,
): Boolean = veneraComparableCacheHeaders(first.veneraStringHeaders()) ==
    veneraComparableCacheHeaders(second.veneraStringHeaders())

private fun JSONObject.veneraStringHeaders(): Map<String, String> =
    keys().asSequence().associateWith { key -> optString(key) }

private fun veneraResponseDisallowsStorage(headers: JSONObject): Boolean {
    val cacheControl = headers.veneraStringHeaders().entries
        .firstOrNull { it.key.equals("cache-control", ignoreCase = true) }
        ?.value
        .orEmpty()
    return cacheControl.split(',').any { directive ->
        directive.substringBefore('=').trim().equals("no-store", ignoreCase = true)
    }
}

private fun veneraComparableCacheHeaders(
    headers: Map<String, String>,
): Map<String, String> = headers.entries
    .filterNot { it.key.lowercase(Locale.US) in VENERA_CACHE_IGNORED_HEADERS }
    .associate { it.key.lowercase(Locale.US) to it.value }

internal fun VeneraHttpResponse.withVeneraCacheHit(): VeneraHttpResponse {
    val cacheHeaders = JSONObject(headers.toString())
    cacheHeaders.put("venera-cache", "true")
    return copy(headers = cacheHeaders, body = body.copyOf())
}

private const val VENERA_CACHE_LOG_TAG = "ZicPluginRuntime"
private const val VENERA_NETWORK_MAX_CACHE_BYTES = 10 * 1024 * 1024
private const val VENERA_NETWORK_MAX_CACHE_ENTRY_BYTES = 1024 * 1024
private const val VENERA_NETWORK_SHORT_CACHE_NANOS = 5L * 1_000_000_000L
private const val VENERA_NETWORK_REVALIDATION_NANOS =
    2L * 60L * 60L * 1_000_000_000L
private const val VENERA_NETWORK_LONG_CACHE_NANOS = 6L * 60L * 60L * 1_000_000_000L
private const val VENERA_NETWORK_LONG_CACHE_MILLIS = 6L * 60L * 60L * 1_000L
private const val VENERA_PERSISTENT_CACHE_MAGIC = 0x5A564843
private const val VENERA_PERSISTENT_CACHE_VERSION = 1
private const val VENERA_PERSISTENT_CACHE_MAX_HEADER_BYTES = 256 * 1024
private val VENERA_CACHE_IGNORED_HEADERS = setOf(
    "cache-time",
    "prevent-parallel",
    "date",
    "x-varnish",
    "cf-ray",
    "connection",
    "vary",
    "content-encoding",
    "report-to",
    "server-timing",
    "token",
    "set-cookie",
    "cf-cache-status",
    "cf-request-id",
    "authorization",
)
