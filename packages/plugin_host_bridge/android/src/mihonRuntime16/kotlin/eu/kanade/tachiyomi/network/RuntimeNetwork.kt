package eu.kanade.tachiyomi.network

import android.content.Context
import android.webkit.CookieManager
import dev.zic.mihonruntime.FallbackDns
import dev.zic.mihonruntime.RuntimeCloudflareInterceptor
import java.util.concurrent.TimeUnit
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
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
            .callTimeout(15, TimeUnit.SECONDS)
            .addInterceptor(
                RuntimeCloudflareInterceptor(context, ::defaultUserAgentProvider),
            )
            .build()
    }
}

private class AndroidCookieJar : CookieJar {
    private val manager: CookieManager
        get() = CookieManager.getInstance()

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        cookies.forEach { cookie -> manager.setCookie(url.toString(), cookie.toString()) }
        manager.flush()
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> =
        manager.getCookie(url.toString())
            .orEmpty()
            .split(';')
            .map(String::trim)
            .filter(String::isNotEmpty)
            .mapNotNull { value -> Cookie.parse(url, value) }
}
