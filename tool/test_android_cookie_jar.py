#!/usr/bin/env python3
"""Execute the production CookieJar with real OkHttp; the Android mirror is delayed."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCookieJar.kt'


def verify_network_helper_priorities(compiler, java, libraries, work):
    dependencies = work / 'NetworkDependencies.kt'
    dependencies.write_text('''package dev.zic.network
import android.content.Context
import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.Interceptor
class FallbackDns : Dns {
    override fun lookup(hostname: String) = Dns.SYSTEM.lookup(hostname)
}
class AndroidCloudflareInterceptor(context: Context, provider: () -> String,
    hasClearance: (HttpUrl) -> Boolean) : Interceptor {
    override fun intercept(chain: Interceptor.Chain) = chain.proceed(chain.request())
}
''')
    harness = work / 'UserAgentPriority.kt'
    harness.write_text('''import android.content.Context
import android.webkit.CookieManager
import dev.zic.network.AndroidBrowserCookieSession
import dev.zic.network.BrowserCookieSnapshot
import eu.kanade.tachiyomi.network.NetworkHelper
import okhttp3.Request
import okhttp3.Response
import okhttp3.Protocol
import okhttp3.ResponseBody.Companion.toResponseBody

fun main() {
    val helper = NetworkHelper(Context())
    CookieManager.current.header = null
    val client = helper.client.newBuilder().addInterceptor { chain ->
        val request = chain.request()
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1)
            .code(200).message("OK").body("".toResponseBody()).build()
    }.build()
    fun actual(browser: String?, source: String?): String? {
        AndroidBrowserCookieSession.snapshot = browser?.let {
            BrowserCookieSnapshot(emptyMap(), it, System.currentTimeMillis())
        }
        val request = Request.Builder().url("https://example.invalid/image")
        if (source != null) request.header("User-Agent", source)
        return client.newCall(request.build()).execute().use {
            it.request.header("User-Agent")
        }
    }
    check(actual(null, null) == helper.defaultUserAgentProvider())
    check(actual(null, "SourceOwnedUA") == "SourceOwnedUA")
    check(actual("BrowserUA/one", "GlobalUA/one") == "BrowserUA/one")
    check(actual("BrowserUA/two", "GlobalUA/two") == "BrowserUA/two")
    check(actual("BrowserUA/two", "SourceOwnedUA") == "BrowserUA/two")
    println("Mihon NetworkHelper actual OkHttp UA priority: 5/5")
}
''')
    common = ROOT / 'packages/plugin_host_bridge/android/src/mihonRuntimeCommon/kotlin/eu/kanade/tachiyomi/network/interceptor'
    for abi in ('mihonRuntime14', 'mihonRuntime16'):
        runtime = ROOT / f'packages/plugin_host_bridge/android/src/{abi}/kotlin/eu/kanade/tachiyomi/network/RuntimeNetwork.kt'
        output = work / f'{abi}-ua.jar'
        sources = [SOURCE, dependencies, harness, work / 'Context.kt',
            work / 'CookieManager.kt', work / 'BrowserSession.kt']
        sources.extend(common / f'{name}.kt' for name in
            ('UncaughtExceptionInterceptor', 'UserAgentInterceptor', 'CloudflareInterceptor'))
        subprocess.run([compiler, '-cp', os.pathsep.join(libraries),
            *map(str, sources), str(runtime), '-include-runtime', '-d', str(output)], check=True)
        subprocess.run([java, '-cp', os.pathsep.join([str(output), *libraries]),
            'UserAgentPriorityKt'], check=True)


def main():
    compiler = shutil.which('kotlinc')
    java = shutil.which('java')
    if not compiler or not java:
        print('SKIP: kotlinc/java unavailable for Android CookieJar contract')
        return 0
    cache = Path(os.environ.get('GRADLE_USER_HOME', str(Path.home() / '.gradle'))) / 'caches/modules-2/files-2.1'
    libraries = []
    for group, name, version in [('com.squareup.okhttp3', 'okhttp-jvm', '5.4.0'),
            ('com.squareup.okio', 'okio-jvm', '3.17.0')]:
        jars = list((cache / group / name / version).glob('*/*.jar'))
        if len(jars) != 1:
            print(f'SKIP: resolved {name} {version} jar unavailable for CookieJar contract')
            return 0
        libraries.append(str(jars[0]))
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        (work / 'Context.kt').write_text('''package android.content
class Context { val applicationContext: Context get() = this }
''')
        (work / 'CookieManager.kt').write_text('''package android.webkit
class CookieManager {
    companion object { val current = CookieManager(); @JvmStatic fun getInstance() = current }
    var header: String? = null
    val writes = mutableListOf<Pair<String, String>>()
    fun getCookie(url: String): String? = header
    fun setCookie(url: String, value: String) { writes.add(url to value) }
    fun flush() {}
}
''')
        (work / 'BrowserSession.kt').write_text('''package dev.zic.network
import android.content.Context
class BrowserCookieSnapshot(val cookies: Map<String, String>, val userAgent: String, val revision: Long)
object AndroidBrowserCookieSession {
    var snapshot: BrowserCookieSnapshot? = null
    fun resetAllImports() {}
    fun readCookies(context: Context, url: String, expectedUserAgent: String?): BrowserCookieSnapshot? = snapshot
}
''')
        verify_network_helper_priorities(compiler, java, libraries, work)
        (work / 'Smoke.kt').write_text('''import android.content.Context
import android.webkit.CookieManager
import dev.zic.network.AndroidBrowserCookieSession
import dev.zic.network.AndroidCookieJar
import dev.zic.network.BrowserCookieSnapshot
import okhttp3.Cookie
import okhttp3.HttpUrl.Companion.toHttpUrl

fun main() {
    val failures = mutableListOf<String>()
    var cases = 0
    fun test(name: String, body: (AndroidCookieJar) -> Unit) {
        cases++
        CookieManager.current.header = null
        CookieManager.current.writes.clear()
        AndroidBrowserCookieSession.snapshot = null
        try { body(AndroidCookieJar(Context()) { "SourceUA" }); println("PASS: $name") }
        catch (error: Throwable) { failures.add(name); println("FAIL: $name: ${error.message}") }
    }
    val secure = "https://example.invalid/seed".toHttpUrl()
    fun cookie(value: String) = Cookie.parse(secure, value) ?: error("Invalid test cookie")
    fun pairs(jar: AndroidCookieJar, url: String) = jar.get(url.toHttpUrl()).map { it.name + "=" + it.value }
    test("path includes its exact and descendant segments only") { jar ->
        jar.saveFromResponse(secure, listOf(cookie("private=present; Path=/private")))
        check(pairs(jar, "https://example.invalid/outside").isEmpty())
        check(pairs(jar, "https://example.invalid/private")==listOf("private=present"))
        check(pairs(jar, "https://example.invalid/private/child")==listOf("private=present"))
        check(pairs(jar, "https://example.invalid/private-other").isEmpty())
    }
    test("secure cookie requires HTTPS") { jar ->
        jar.saveFromResponse(secure, listOf(cookie("secure=present; Path=/; Secure")))
        check(pairs(jar, "http://example.invalid/").isEmpty())
        check(pairs(jar, "https://example.invalid/")==listOf("secure=present"))
    }
    test("host-only excludes child hosts") { jar ->
        jar.saveFromResponse(secure, listOf(cookie("host=present; Path=/")))
        check(pairs(jar, "https://child.example.invalid/").isEmpty())
        check(pairs(jar, "https://example.invalid/")==listOf("host=present"))
    }
    test("domain cookie includes children without matching sibling suffixes") { jar ->
        jar.saveFromResponse(secure, listOf(cookie("domain=present; Domain=example.invalid; Path=/")))
        check(pairs(jar, "https://child.example.invalid/")==listOf("domain=present"))
        check(pairs(jar, "https://badexample.invalid/").isEmpty())
        check(pairs(jar, "https://elsewhere.invalid/").isEmpty())
    }
    test("same name retains both path identities") { jar ->
        jar.saveFromResponse(secure, listOf(cookie("same=root; Path=/"),cookie("same=private; Path=/private")))
        check(pairs(jar, "https://example.invalid/outside")==listOf("same=root"))
        check(pairs(jar, "https://example.invalid/private/child")==listOf("same=private","same=root"))
        check(pairs(jar, "https://example.invalid/private/child").size==2)
    }
    test("same domain path identity replaces only its own value") { jar ->
        jar.saveFromResponse(secure, listOf(cookie("same=root; Path=/"),cookie("same=private; Path=/private")))
        jar.saveFromResponse(secure, listOf(cookie("same=new; Path=/")))
        check(pairs(jar, "https://example.invalid/private/child").toSet()==setOf("same=new","same=private"))
    }
    test("equal values at distinct paths remain distinct cookies") { jar ->
        jar.saveFromResponse(secure, listOf(cookie("same=value; Path=/"),cookie("same=value; Path=/private")))
        check(pairs(jar, "https://example.invalid/private/child")==listOf("same=value","same=value"))
    }
    test("expiry is checked independently of URL matching") { jar ->
        val expired = Cookie.Builder().name("expired").value("present").hostOnlyDomain("example.invalid")
            .path("/").expiresAt(System.currentTimeMillis()-1000).build()
        jar.saveFromResponse(secure, listOf(expired))
        check(pairs(jar, "https://example.invalid/").isEmpty())
    }
    test("empty values are valid cookies") { jar ->
        jar.saveFromResponse(secure, listOf(cookie("empty=; Path=/")))
        check(pairs(jar, "https://example.invalid/")==listOf("empty="))
    }
    test("delayed mirror cannot resurrect deleted identity") { jar ->
        jar.saveFromResponse(secure, listOf(cookie("root=old; Path=/")))
        CookieManager.current.header = "root=old; unrelated=present"
        jar.saveFromResponse(secure, listOf(cookie("root=; Path=/; Max-Age=0")))
        check(pairs(jar, "https://example.invalid/")==listOf("unrelated=present"))
    }
    test("delayed mirror cannot broaden known Secure scope") { jar ->
        jar.saveFromResponse(secure, listOf(cookie("secure=present; Path=/; Secure")))
        CookieManager.current.header = "secure=present; unknown=present"
        check(pairs(jar, "http://example.invalid/outside")==listOf("unknown=present"))
    }
    test("unknown mirror identity survives a same-name cookie at a different path") { jar ->
        jar.saveFromResponse(secure, listOf(cookie("same=value; Path=/private")))
        CookieManager.current.header = "same=value"
        check(pairs(jar, "https://example.invalid/outside")==listOf("same=value"))
        check(pairs(jar, "https://example.invalid/private-other")==listOf("same=value"))
        jar.saveFromResponse(secure, listOf(cookie("same=; Path=/private; Max-Age=0")))
        check(pairs(jar, "https://example.invalid/outside")==listOf("same=value"))
    }
    test("deletion at root preserves same-name private identity") { jar ->
        jar.saveFromResponse(secure, listOf(cookie("same=root; Path=/"),cookie("same=private; Path=/private")))
        jar.saveFromResponse(secure, listOf(cookie("same=; Path=/; Max-Age=0")))
        check(pairs(jar, "https://example.invalid/private/child")==listOf("same=private"))
    }
    test("unobserved Android mirror cookies still load") { jar ->
        CookieManager.current.header = "mirror=present; empty="
        check(pairs(jar, "https://example.invalid/")==listOf("mirror=present","empty="))
    }
    test("browser handoff is immediate and revision-scoped with matching UA") { jar ->
        CookieManager.current.header = "cf_clearance=stale"
        AndroidBrowserCookieSession.snapshot = BrowserCookieSnapshot(mapOf("cf_clearance" to "browser"),"BrowserUA",1)
        check(pairs(jar, "https://example.invalid/api")==listOf("cf_clearance=browser"))
        check(jar.browserSessionUserAgent(secure)=="BrowserUA")
        jar.saveFromResponse(secure, listOf(cookie("cf_clearance=network; Path=/")))
        check(pairs(jar, "https://example.invalid/api")==listOf("cf_clearance=network"))
        AndroidBrowserCookieSession.snapshot = BrowserCookieSnapshot(mapOf("cf_clearance" to "new-browser"),"BrowserUA",2)
        check(pairs(jar, "https://example.invalid/api")==listOf("cf_clearance=new-browser"))
    }
    println("Android CookieJar: $cases cases, ${failures.size} failures")
    check(failures.isEmpty()) { failures.joinToString() }
}
''')
        jar = work / 'contract.jar'
        subprocess.run([compiler, str(SOURCE), *(str(work / name) for name in
            ['Context.kt','CookieManager.kt','BrowserSession.kt','Smoke.kt']),
            '-classpath', os.pathsep.join(libraries), '-include-runtime', '-d', str(jar)], check=True)
        subprocess.run([java, '-cp', os.pathsep.join([str(jar), *libraries]), 'SmokeKt'], check=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
