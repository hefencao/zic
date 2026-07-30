package eu.kanade.tachiyomi.network

import android.content.Context

@Suppress("UNUSED", "UNCHECKED_CAST")
class JavaScriptEngine(@Suppress("UNUSED_PARAMETER") context: Context) {
    suspend fun <T> evaluate(script: String): T {
        val type = Class.forName("app.cash.quickjs.QuickJs")
        val engine = type.getMethod("create").invoke(null)
        try {
            return type.getMethod("evaluate", String::class.java).invoke(engine, script) as T
        } finally {
            (engine as? AutoCloseable)?.close()
                ?: runCatching { type.getMethod("close").invoke(engine) }
        }
    }
}
