package eu.kanade.tachiyomi.util

import okhttp3.Response
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element

fun Element.selectText(css: String, defaultValue: String? = null): String? =
    select(css).first()?.text() ?: defaultValue

fun Element.selectInt(css: String, defaultValue: Int = 0): Int =
    select(css).first()?.text()?.toInt() ?: defaultValue

fun Element.attrOrText(css: String): String =
    if (css != "text") attr(css) else text()

fun Response.asJsoup(html: String? = null): Document =
    Jsoup.parse(html ?: body.string(), request.url.toString())
