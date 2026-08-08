#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    ROOT / 'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCloudflareInterceptor.kt',
    ROOT / 'packages/plugin_host_bridge/android/src/mihonRuntimeCommon/kotlin/dev/zic/mihonruntime/RuntimeCloudflareInterceptor.kt',
)


def main() -> int:
    kotlinc = shutil.which('kotlinc')
    javac = shutil.which('javac')
    if not kotlinc or not javac:
        print('SKIP: kotlinc/javac are unavailable for Cloudflare classifier compilation')
        return 0

    java_sources = {
        'android/content/Context.java': '''package android.content; public class Context {}''',
        'okhttp3/HttpUrl.java': '''package okhttp3; public class HttpUrl { public String toString(){ return "https://example.invalid/"; } }''',
        'okhttp3/Request.java': '''package okhttp3; public class Request { public HttpUrl getUrl(){ return new HttpUrl(); } }''',
        'okhttp3/ResponseBody.java': '''package okhttp3; public class ResponseBody { public String string(){ return ""; } }''',
        'okhttp3/Response.java': '''package okhttp3; public class Response { public int getCode(){ return 403; } public Request getRequest(){ return new Request(); } public String header(String name){ return null; } public ResponseBody peekBody(long limit){ return new ResponseBody(); } public void close(){} }''',
        'okhttp3/Interceptor.java': '''package okhttp3; public interface Interceptor { Response intercept(Chain chain) throws java.io.IOException; interface Chain { Request request(); Response proceed(Request request) throws java.io.IOException; } }''',
    }

    with tempfile.TemporaryDirectory() as raw:
        temp = Path(raw)
        classes = temp / 'classes'
        classes.mkdir()
        java_paths: list[str] = []
        for relative, text in java_sources.items():
            path = temp / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding='utf-8')
            java_paths.append(str(path))
        subprocess.run([javac, '-d', str(classes), *java_paths], check=True)
        behavior = temp / 'CloudflareClassifierBehavior.kt'
        behavior.write_text(
            '''package dev.zic.network

private fun expect(value: Boolean, message: String) {
    if (!value) throw IllegalStateException(message)
}

fun main() {
    expect(isCloudflareVerificationResponse(403, "challenge", null, ""), "cf-mitigated challenge")
    expect(
        isCloudflareVerificationResponse(
            403,
            null,
            "cloudflare",
            "<div id='challenge-error-title'>Just a moment</div>",
        ),
        "Mihon challenge title",
    )
    expect(
        isCloudflareVerificationResponse(
            503,
            null,
            "cloudflare-nginx",
            "<div id='challenge-error-text'>Enable JavaScript</div>",
        ),
        "Mihon challenge text",
    )

    expect(!isCloudflareVerificationResponse(200, "challenge", "cloudflare", "<div id='challenge-error-title'>x</div>"), "status gate")
    expect(!isCloudflareVerificationResponse(403, null, null, "<div id='challenge-error-title'>x</div>"), "Cloudflare server gate")
    expect(!isCloudflareVerificationResponse(403, null, "cloudflare", "<script src='/cdn-cgi/challenge-platform/x'></script>"), "challenge script is not an interactive captcha")
    expect(!isCloudflareVerificationResponse(503, null, "cloudflare", "window._cf_chl_opt = {}; cf-chl-test"), "cf-chl script is not enough")
    expect(!isCloudflareVerificationResponse(403, null, "cloudflare", "<title>Just a moment</title>"), "title is not enough")
    expect(!isCloudflareVerificationResponse(403, null, "cloudflare", "Forbidden"), "server header alone")
    expect(!isCloudflareVerificationResponse(403, null, null, "Forbidden"), "ordinary 403")
    expect(!isCloudflareVerificationResponse(503, null, null, "Service unavailable"), "ordinary 503")
}
''',
            encoding='utf-8',
        )
        output = temp / 'classifier.jar'
        subprocess.run(
            [
                kotlinc,
                *(str(path) for path in SOURCES),
                str(behavior),
                '-classpath',
                str(classes),
                '-include-runtime',
                '-d',
                str(output),
            ],
            check=True,
        )
        subprocess.run(
            [
                'java',
                '-cp',
                f'{output}:{classes}',
                'dev.zic.network.CloudflareClassifierBehaviorKt',
            ],
            check=True,
        )
    print('Cloudflare typed classifier/wrapper compilation and behavior: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
