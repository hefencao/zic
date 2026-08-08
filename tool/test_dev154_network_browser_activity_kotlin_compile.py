#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ACTIVITY = ROOT / 'packages/network_bridge/android/src/main/kotlin/dev/zic/network/NetworkBrowserActivity.kt'


def main() -> int:
    kotlinc = shutil.which('kotlinc')
    javac = shutil.which('javac')
    if not kotlinc or not javac:
        print('SKIP: kotlinc/javac unavailable for dev.154 NetworkBrowserActivity compile')
        return 0

    java_sources = {
        'android/content/Context.java': '''package android.content; public class Context { public java.io.File getFilesDir(){ return new java.io.File("."); } }''',
        'android/content/Intent.java': '''package android.content; public class Intent { public Intent(){} public String getStringExtra(String k){return null;} public boolean getBooleanExtra(String k,boolean d){return d;} public Intent putExtra(String k,String v){return this;} public Intent putExtra(String k,boolean v){return this;} }''',
        'android/os/Bundle.java': '''package android.os; public class Bundle {}''',
        'android/os/Looper.java': '''package android.os; public class Looper { public static Looper getMainLooper(){ return new Looper(); } }''',
        'android/os/Handler.java': '''package android.os; public class Handler { public Handler(Looper l){} public boolean postDelayed(Runnable r,long d){ return true; } public void removeCallbacksAndMessages(Object token){} }''',
        'android/os/SystemClock.java': '''package android.os; public class SystemClock { public static long uptimeMillis(){ return 0L; } }''',
        'android/graphics/Bitmap.java': '''package android.graphics; public class Bitmap {}''',
        'android/view/ViewGroup.java': '''package android.view; public class ViewGroup { public static class LayoutParams { public static final int MATCH_PARENT=-1; public LayoutParams(int w,int h){} } }''',
        'android/webkit/ValueCallback.java': '''package android.webkit; public interface ValueCallback<T> { void onReceiveValue(T value); }''',
        'android/webkit/WebSettings.java': '''package android.webkit; public class WebSettings { public void setJavaScriptEnabled(boolean v){} public boolean getJavaScriptEnabled(){return true;} public void setDomStorageEnabled(boolean v){} public boolean getDomStorageEnabled(){return true;} public void setDatabaseEnabled(boolean v){} public boolean getDatabaseEnabled(){return true;} public void setUserAgentString(String v){} public String getUserAgentString(){return "ua";} }''',
        'android/webkit/WebViewClient.java': '''package android.webkit; public class WebViewClient { public void onPageStarted(WebView v,String u,android.graphics.Bitmap b){} public void onPageFinished(WebView v,String u){} }''',
        'android/webkit/WebView.java': '''package android.webkit; public class WebView { public WebView(android.content.Context c){} public void setLayoutParams(android.view.ViewGroup.LayoutParams p){} public android.view.ViewGroup.LayoutParams getLayoutParams(){return null;} public WebSettings getSettings(){return new WebSettings();} public void setWebViewClient(WebViewClient c){} public WebViewClient getWebViewClient(){return null;} public void loadUrl(String u){} public String getUrl(){return "https://18comic.vip/";} public int getProgress(){return 100;} public void evaluateJavascript(String s,ValueCallback<String> c){c.onReceiveValue("[\\\"complete\\\",false]");} public String getTitle(){return "title";} public boolean canGoBack(){return false;} public void goBack(){} public void stopLoading(){} public void destroy(){} }''',
        'android/webkit/CookieManager.java': '''package android.webkit; public class CookieManager { private static final CookieManager I=new CookieManager(); public static CookieManager getInstance(){return I;} public void setAcceptCookie(boolean v){} public void setAcceptThirdPartyCookies(WebView v,boolean a){} public String getCookie(String u){return "session=x";} public void flush(){} }''',
        'android/app/Activity.java': '''package android.app; public class Activity extends android.content.Context { public static final int RESULT_CANCELED=0, RESULT_OK=-1, RESULT_FIRST_USER=1; private final android.content.Intent intent=new android.content.Intent(); protected void onCreate(android.os.Bundle b){} public android.content.Intent getIntent(){return intent;} public void setResult(int r){} public void setResult(int r,android.content.Intent i){} public void setContentView(Object v){} public void finish(){} public boolean isFinishing(){return false;} public boolean isDestroyed(){return false;} public void onBackPressed(){} protected void onDestroy(){} }''',
        'org/json/JSONArray.java': '''package org.json; public class JSONArray { public JSONArray(String s){} public String optString(int i){return i==0?"complete":"";} public boolean optBoolean(int i,boolean d){return false;} }''',
    }
    kotlin_support = '''package dev.zic.network\ninternal object NetworkBrowserSnapshotStore {\n fun begin(context: android.content.Context, requestedUrl: String, userAgent: String?) {}\n fun update(context: android.content.Context, currentUrl: String, title: String?, cookieHeader: String?, localStorageJson: String? = null, userAgent: String? = null) {}\n}\n'''

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
        support = temp / 'NetworkBrowserSnapshotStore.kt'
        support.write_text(kotlin_support, encoding='utf-8')
        output = temp / 'activity.jar'
        subprocess.run(
            [
                kotlinc,
                str(ACTIVITY),
                str(support),
                '-classpath',
                str(classes),
                '-d',
                str(output),
            ],
            check=True,
        )
    print('dev.154 NetworkBrowserActivity Kotlin compile: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
