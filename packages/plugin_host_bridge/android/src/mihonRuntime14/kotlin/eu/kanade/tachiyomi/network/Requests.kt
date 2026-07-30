@file:Suppress("FunctionName")

package eu.kanade.tachiyomi.network

import java.util.concurrent.TimeUnit
import okhttp3.CacheControl
import okhttp3.FormBody
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.Request
import okhttp3.RequestBody

private val defaultCacheControl = CacheControl.Builder()
    .maxAge(10, TimeUnit.MINUTES)
    .build()
private val defaultHeaders = Headers.Builder().build()
private val defaultBody: RequestBody = FormBody.Builder().build()

fun GET(
    url: String,
    headers: Headers = defaultHeaders,
    cache: CacheControl = defaultCacheControl,
): Request = Request.Builder()
    .url(url)
    .headers(headers)
    .cacheControl(cache)
    .build()

fun GET(
    url: HttpUrl,
    headers: Headers = defaultHeaders,
    cache: CacheControl = defaultCacheControl,
): Request = Request.Builder()
    .url(url)
    .headers(headers)
    .cacheControl(cache)
    .build()

fun POST(
    url: String,
    headers: Headers = defaultHeaders,
    body: RequestBody = defaultBody,
    cache: CacheControl = defaultCacheControl,
): Request = Request.Builder()
    .url(url)
    .post(body)
    .headers(headers)
    .cacheControl(cache)
    .build()
