package eu.kanade.tachiyomi.network

import android.content.Context
import dev.zic.network.AndroidCloudflareInterceptor
import dev.zic.network.AndroidCookieJar
import dev.zic.network.FallbackDns
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient

class NetworkHelper(context: Context) {
    val client: OkHttpClient
        get() = sharedClient

    fun defaultUserAgentProvider(): String =
        "Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 Chrome/131 Mobile Safari/537.36"

    private val sharedClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .cookieJar(AndroidCookieJar())
            .dns(FallbackDns())
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .callTimeout(45, TimeUnit.SECONDS)
            .addInterceptor(
                AndroidCloudflareInterceptor(context, ::defaultUserAgentProvider),
            )
            .build()
    }
}
