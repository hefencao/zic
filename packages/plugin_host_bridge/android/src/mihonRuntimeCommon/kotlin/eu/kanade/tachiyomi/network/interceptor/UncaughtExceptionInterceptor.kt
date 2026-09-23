package eu.kanade.tachiyomi.network.interceptor

import java.io.IOException
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Preserves Mihon's default-client contract: exceptions thrown later in the
 * interceptor chain are converted to non-fatal IO failures.
 *
 * This interceptor must be installed first in NetworkHelper.client.
 */
class UncaughtExceptionInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        return try {
            chain.proceed(chain.request())
        } catch (error: Exception) {
            if (error is IOException) {
                throw error
            }
            throw IOException(error)
        }
    }
}
