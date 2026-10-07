package dev.zic.pluginhost

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.Closeable
import java.io.File
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

internal interface NativeExternalPluginDriver : Closeable {
    val driverId: String
    val runtimeId: String
    val sources: List<Map<String, Any?>>

    fun invoke(request: Map<String, Any?>, result: NativeDriverResult)
    fun cancel(requestId: String)
    fun closeWhenDrained(): CompletableFuture<Unit>
}

internal interface NativeDriverResult {
    fun success(value: Any)
    fun error(
        code: String,
        message: String,
        retryable: Boolean = false,
        details: Map<String, Any?> = emptyMap(),
    )
}

internal class NativeExternalPluginDriverHost(
    private val context: Context,
    private val veneraResolverHttp: VeneraResolverHttpTransport,
) : Closeable {
    private val veneraNetworkCache = VeneraHttpCacheStore(
        persistentRoot = File(context.cacheDir, "venera_http_long_cache"),
    )
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "zic-native-plugin-driver").apply { isDaemon = true }
    }
    private val cacheCleanup: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "zic-mihon-cache-cleanup").apply { isDaemon = true }
    }
    private class DriverEntry(
        val driver: NativeExternalPluginDriver,
        val lifetime: NativeRuntimeWorkDrain.Work,
    )

    private val drivers = ConcurrentHashMap<String, DriverEntry>()
    private val nativeWork = NativeRuntimeWorkDrain()
    private val closeCompletion = CompletableFuture<Unit>()
    @Volatile private var closed = false

    init {
        // Legacy per-driver roots can contain large extracted plugin state.
        // They are maintenance work and must not run on the service main
        // thread, which is also responsible for Binder/Flutter bootstrap.
        val cleanup = checkNotNull(nativeWork.begin())
        cacheCleanup.execute {
            try {
                runCatching { cleanupStaleMihonRuntimeRoots(context.codeCacheDir) }
            } finally {
                cleanup.finish()
            }
        }
    }

    fun handles(method: String): Boolean = method in METHODS

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (closed) {
            result.error("native-runtime-closed", "native runtime host is closed", null)
            return
        }
        try {
            when (call.method) {
                CREATE -> create(call.arguments, result)
                INVOKE -> invoke(call.arguments, result)
                CANCEL -> cancel(call.arguments, result)
                CLOSE -> closeDriver(call.arguments, result)
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            result.error(
                "native-runtime-message-invalid",
                error.sanitizedMessage(),
                null,
            )
        }
    }

    private fun create(arguments: Any?, result: MethodChannel.Result) {
        val message = arguments.stringMap("native driver activation")
        val format = message.requireString("format")
        val activation = message["activation"].stringMap("native activation")
        val payloadPath = message.requireString("payloadPath")
        val payloadLength = message.requireLong("payloadByteLength")
        val payloadSha256 = message.requireString("payloadSha256")
        val driverId = "native-${UUID.randomUUID()}"
        val lifetime = nativeWork.begin()
        if (lifetime == null) {
            result.error("native-runtime-closed", "native runtime host is closed", null)
            return
        }
        when (format) {
            "mihonExtension" -> {
                try {
                    worker.execute {
                        runCatching {
                            MihonRuntimeDriver.create(
                                context = context,
                                driverId = driverId,
                                activation = activation,
                                payloadPath = payloadPath,
                                payloadLength = payloadLength,
                                payloadSha256 = payloadSha256,
                                executor = worker,
                            )
                        }.fold(
                            onSuccess = { driver ->
                                mainHandler.post { activated(driver, lifetime, result) }
                            },
                            onFailure = { error ->
                                mainHandler.post {
                                    try {
                                        result.error(
                                            "mihon-driver-activation-failed",
                                            error.sanitizedMessage(),
                                            null,
                                        )
                                    } finally {
                                        lifetime.finish()
                                    }
                                }
                            },
                        )
                    }
                } catch (error: Throwable) {
                    lifetime.finish()
                    throw error
                }
            }
            "veneraJavaScript" -> {
                check(Looper.myLooper() == Looper.getMainLooper())
                runCatching {
                    VeneraRuntimeDriver.create(
                        context = context,
                        driverId = driverId,
                        activation = activation,
                        payloadPath = payloadPath,
                        payloadLength = payloadLength,
                        payloadSha256 = payloadSha256,
                        executor = worker,
                        resolverHttp = veneraResolverHttp,
                        networkCache = veneraNetworkCache,
                    ) { driverResult ->
                        driverResult.fold(
                            onSuccess = { driver ->
                                activated(driver, lifetime, result)
                            },
                            onFailure = { error ->
                                try {
                                    result.error(
                                        "venera-driver-activation-failed",
                                        error.sanitizedMessage(),
                                        null,
                                    )
                                } finally {
                                    lifetime.finish()
                                }
                            },
                        )
                    }
                }.onFailure { error ->
                    try {
                        result.error(
                            "venera-driver-activation-failed",
                            error.sanitizedMessage(),
                            null,
                        )
                    } finally {
                        lifetime.finish()
                    }
                }
            }
            else -> {
                try {
                    result.error(
                        "native-runtime-format-unsupported",
                        "unsupported native runtime format",
                        null,
                    )
                } finally {
                    lifetime.finish()
                }
            }
        }
    }

    private fun activated(
        driver: NativeExternalPluginDriver,
        lifetime: NativeRuntimeWorkDrain.Work,
        result: MethodChannel.Result,
    ) {
        val entry = DriverEntry(driver, lifetime)
        drivers[driver.driverId] = entry
        if (closed) {
            retire(entry) {
                result.error("native-runtime-closed", "native runtime host is closed", null)
            }
        } else {
            result.success(driver.activationMessage())
        }
    }

    private fun invoke(arguments: Any?, result: MethodChannel.Result) {
        val message = arguments.stringMap("native driver invocation")
        val driver = drivers[message.requireString("driverId")]?.driver
        if (driver == null) {
            result.error("native-driver-missing", "native runtime driver is not active", null)
            return
        }
        val request = message["request"].stringMap("native runtime request")
        driver.invoke(
            request,
            object : NativeDriverResult {
                override fun success(value: Any) {
                    mainHandler.post { result.success(value) }
                }

                override fun error(
                    code: String,
                    message: String,
                    retryable: Boolean,
                    details: Map<String, Any?>,
                ) {
                    mainHandler.post {
                        result.error(
                            code,
                            message,
                            mapOf("retryable" to retryable) + details,
                        )
                    }
                }
            },
        )
    }

    private fun cancel(arguments: Any?, result: MethodChannel.Result) {
        val message = arguments.stringMap("native driver cancellation")
        val driver = drivers[message.requireString("driverId")]?.driver
        if (driver == null) {
            result.success(null)
            return
        }
        driver.cancel(message.requireString("requestId"))
        result.success(null)
    }

    private fun closeDriver(arguments: Any?, result: MethodChannel.Result) {
        val message = arguments.stringMap("native driver close")
        val entry = drivers[message.requireString("driverId")]
        if (entry == null) {
            result.success(null)
            return
        }
        val reply = checkNotNull(nativeWork.begin())
        retire(entry) { failure ->
            try {
                if (failure == null) {
                    result.success(null)
                } else {
                    result.error(
                        "native-driver-close-failed",
                        failure.sanitizedMessage(),
                        null,
                    )
                }
            } finally {
                reply.finish()
            }
        }
    }

    private fun retire(entry: DriverEntry, onClosed: ((Throwable?) -> Unit)? = null) {
        entry.driver.closeWhenDrained().whenComplete { _, failure ->
            mainHandler.post {
                try {
                    onClosed?.invoke(failure)
                } finally {
                    if (drivers.remove(entry.driver.driverId, entry)) entry.lifetime.finish()
                }
            }
        }
    }

    override fun close() {
        closeWhenDrained()
    }

    fun closeWhenDrained(): CompletableFuture<Unit> {
        // Host admission, activation delivery and teardown run on Main.
        check(Looper.myLooper() == Looper.getMainLooper())
        if (closed) return closeCompletion
        closed = true
        val drained = nativeWork.close()
        drivers.values.toList().forEach { retire(it) }
        drained.whenComplete { _, _ ->
            mainHandler.post {
                runCatching {
                    veneraNetworkCache.clearMemory()
                    veneraResolverHttp.close()
                    worker.shutdown()
                    cacheCleanup.shutdown()
                }.fold(
                    onSuccess = { closeCompletion.complete(Unit) },
                    onFailure = { closeCompletion.completeExceptionally(it) },
                )
            }
        }
        return closeCompletion
    }

    companion object {
        const val CREATE = "createNativeExternalPluginDriver"
        const val INVOKE = "invokeNativeExternalPluginDriver"
        const val CANCEL = "cancelNativeExternalPluginDriver"
        const val CLOSE = "closeNativeExternalPluginDriver"
        private val METHODS = setOf(CREATE, INVOKE, CANCEL, CLOSE)
    }
}

private fun NativeExternalPluginDriver.activationMessage(): Map<String, Any?> = mapOf(
    "driverId" to driverId,
    "runtimeId" to runtimeId,
    "sources" to sources,
)

internal fun Any?.stringMap(label: String): Map<String, Any?> {
    val raw = this as? Map<*, *> ?: error("$label must be an object")
    require(raw.keys.all { it is String }) { "$label keys must be strings" }
    @Suppress("UNCHECKED_CAST")
    return raw as Map<String, Any?>
}

internal fun Map<String, Any?>.requireString(key: String): String {
    val value = this[key] as? String
    require(!value.isNullOrBlank()) { "$key is missing" }
    return value
}

internal fun Map<String, Any?>.requireLong(key: String): Long = when (val value = this[key]) {
    is Long -> value
    is Int -> value.toLong()
    else -> error("$key is missing")
}

internal fun Throwable.sanitizedMessage(): String {
    var current = this
    val visited = java.util.Collections.newSetFromMap(
        java.util.IdentityHashMap<Throwable, Boolean>(),
    )
    while (visited.add(current)) {
        current.message?.takeIf { it.isNotBlank() }?.let { return it.take(300) }
        val next = current.cause?.takeUnless { it === current } ?: break
        current = next
    }
    return current.javaClass.simpleName.take(300)
}
