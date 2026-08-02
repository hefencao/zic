package dev.zic.network

import android.webkit.CookieManager
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

class AndroidCookieJar : CookieJar {
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
