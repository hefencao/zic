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
        "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36"

    private val cookieJar by lazy {
        AndroidCookieJar(context, ::defaultUserAgentProvider)
    }

    private val sharedClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .cookieJar(cookieJar)
            .dns(FallbackDns())
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .callTimeout(45, TimeUnit.SECONDS)
            .addInterceptor { chain ->
                val request = chain.request()
                val browserUserAgent = cookieJar.browserSessionUserAgent(request.url)
                val next = if (browserUserAgent == null) {
                    request
                } else {
                    request.newBuilder()
                        .header("User-Agent", browserUserAgent)
                        .build()
                }
                chain.proceed(next)
            }
            .addInterceptor(
                AndroidCloudflareInterceptor(context, ::defaultUserAgentProvider) { url ->
                    cookieJar.get(url).any { cookie ->
                        cookie.name == "cf_clearance" && cookie.value.isNotBlank()
                    }
                },
            )
            .build()
    }
}
