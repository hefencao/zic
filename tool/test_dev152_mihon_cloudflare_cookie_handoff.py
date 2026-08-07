#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COOKIE_JAR = ROOT / 'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCookieJar.kt'


def main() -> int:
    kotlinc = shutil.which('kotlinc')
    javac = shutil.which('javac')
    if not kotlinc or not javac:
        print('SKIP: kotlinc/javac are unavailable for Mihon cookie handoff behavior')
        return 0

    java_sources = {
        'android/content/Context.java': '''package android.content; public class Context { public Context getApplicationContext(){ return this; } }''',
        'android/webkit/CookieManager.java': '''package android.webkit; public class CookieManager { private static final CookieManager INSTANCE=new CookieManager(); public static CookieManager getInstance(){ return INSTANCE; } public String getCookie(String url){ return ""; } public void setCookie(String url,String value){} public void flush(){} }''',
        'okhttp3/HttpUrl.java': '''package okhttp3; public class HttpUrl { private final String value; public HttpUrl(String value){this.value=value;} public String toString(){ return value; } }''',
        'okhttp3/Cookie.java': '''package okhttp3; public class Cookie { private final String name; private final String value; public Cookie(String name,String value){this.name=name;this.value=value;} public static Cookie parse(HttpUrl url,String raw){ int i=raw.indexOf('='); return i<=0?null:new Cookie(raw.substring(0,i),raw.substring(i+1)); } public String getName(){return name;} public String getValue(){return value;} public String toString(){ return name+"="+value; } }''',
        'okhttp3/CookieJar.java': '''package okhttp3; import java.util.List; public interface CookieJar { void saveFromResponse(HttpUrl url,List<Cookie> cookies); List<Cookie> loadForRequest(HttpUrl url); }''',
    }
    kotlin_support = '''package dev.zic.network

internal data class BrowserCookieSnapshot(
    val revision: Long,
    val cookies: Map<String, String>,
    val userAgent: String,
)

internal object AndroidBrowserCookieSession {
    fun resetAllImports() {}
    fun readCookies(
        context: android.content.Context,
        url: String,
        expectedUserAgent: String?,
    ): BrowserCookieSnapshot? = BrowserCookieSnapshot(
        revision = 7L,
        cookies = mapOf("cf_clearance" to "fresh-token", "session" to "abc"),
        userAgent = "Mozilla/5.0 real-webview",
    )
}
'''
    behavior = '''package dev.zic.network

fun main() {
    val jar = AndroidCookieJar(android.content.Context()) { "source-agent" }
    val cookies = jar.loadForRequest(okhttp3.HttpUrl("https://18comic.vip/albums?o=mv&page=1"))
    check(cookies.any { it.name == "cf_clearance" && it.value == "fresh-token" }) {
        "browser snapshot cf_clearance was not available synchronously to the first OkHttp request"
    }
    check(cookies.any { it.name == "session" && it.value == "abc" }) {
        "browser snapshot cookies were not imported into the in-memory jar"
    }
    check(jar.browserSessionUserAgent(okhttp3.HttpUrl("https://18comic.vip/albums")) ==
        "Mozilla/5.0 real-webview") {
        "browser snapshot UA was not exposed with the cookie session"
    }
}
'''

    with tempfile.TemporaryDirectory() as raw:
        temp = Path(raw)
        classes = temp / 'classes'
        classes.mkdir()
        java_paths = []
        for relative, text in java_sources.items():
            path = temp / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding='utf-8')
            java_paths.append(str(path))
        subprocess.run([javac, '-d', str(classes), *java_paths], check=True)
        support = temp / 'BrowserCookieSessionStub.kt'
        support.write_text(kotlin_support, encoding='utf-8')
        runner = temp / 'CookieHandoffBehavior.kt'
        runner.write_text(behavior, encoding='utf-8')
        output = temp / 'handoff.jar'
        subprocess.run(
            [
                kotlinc,
                str(COOKIE_JAR),
                str(support),
                str(runner),
                '-classpath',
                str(classes),
                '-include-runtime',
                '-d',
                str(output),
            ],
            check=True,
        )
        subprocess.run(
            ['java', '-cp', f'{output}:{classes}', 'dev.zic.network.CookieHandoffBehaviorKt'],
            check=True,
        )
    print('Mihon Cloudflare browser-snapshot -> first OkHttp request handoff: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
