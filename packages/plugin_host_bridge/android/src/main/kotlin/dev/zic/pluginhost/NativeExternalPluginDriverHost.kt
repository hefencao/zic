package dev.zic.pluginhost

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.Closeable
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

internal interface NativeExternalPluginDriver : Closeable {
    val driverId: String
    val runtimeId: String
    val sources: List<Map<String, Any?>>

    fun invoke(request: Map<String, Any?>, result: NativeDriverResult)
    fun cancel(requestId: String)
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
    private val veneraNetworkCache = VeneraHttpCacheStore()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "zic-native-plugin-driver").apply { isDaemon = true }
    }
    private val cacheCleanup: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "zic-mihon-cache-cleanup").apply { isDaemon = true }
    }
    private val drivers = ConcurrentHashMap<String, NativeExternalPluginDriver>()
    @Volatile private var closed = false

    init {
        // Legacy per-driver roots can contain large extracted plugin state.
        // They are maintenance work and must not run on the service main
        // thread, which is also responsible for Binder/Flutter bootstrap.
        cacheCleanup.execute {
            runCatching { cleanupStaleMihonRuntimeRoots(context.codeCacheDir) }
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
        when (format) {
            "mihonExtension" -> worker.execute {
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
                        drivers[driver.driverId] = driver
                        mainHandler.post { result.success(driver.activationMessage()) }
                    },
                    onFailure = { error ->
                        mainHandler.post {
                            result.error(
                                "mihon-driver-activation-failed",
                                error.sanitizedMessage(),
                                null,
                            )
                        }
                    },
                )
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
                                drivers[driver.driverId] = driver
                                result.success(driver.activationMessage())
                            },
                            onFailure = { error ->
                                result.error(
                                    "venera-driver-activation-failed",
                                    error.sanitizedMessage(),
                                    null,
                                )
                            },
                        )
                    }
                }.onFailure { error ->
                    result.error(
                        "venera-driver-activation-failed",
                        error.sanitizedMessage(),
                        null,
                    )
                }
            }
            else -> result.error(
                "native-runtime-format-unsupported",
                "unsupported native runtime format",
                null,
            )
        }
    }

    private fun invoke(arguments: Any?, result: MethodChannel.Result) {
        val message = arguments.stringMap("native driver invocation")
        val driver = drivers[message.requireString("driverId")]
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
        val driver = drivers[message.requireString("driverId")]
        if (driver == null) {
            result.success(null)
            return
        }
        driver.cancel(message.requireString("requestId"))
        result.success(null)
    }

    private fun closeDriver(arguments: Any?, result: MethodChannel.Result) {
        val message = arguments.stringMap("native driver close")
        val driver = drivers.remove(message.requireString("driverId"))
        if (driver == null) {
            result.success(null)
            return
        }
        worker.execute {
            runCatching { driver.close() }.fold(
                onSuccess = { mainHandler.post { result.success(null) } },
                onFailure = { error ->
                    mainHandler.post {
                        result.error(
                            "native-driver-close-failed",
                            error.sanitizedMessage(),
                            null,
                        )
                    }
                },
            )
        }
    }

    override fun close() {
        if (closed) return
        closed = true
        val values = drivers.values.toList()
        drivers.clear()
        values.forEach { runCatching { it.close() } }
        veneraNetworkCache.clear()
        veneraResolverHttp.close()
        worker.shutdownNow()
        cacheCleanup.shutdownNow()
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
