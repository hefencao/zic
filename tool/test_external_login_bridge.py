#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    ROOT / 'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/NetworkBrowserSnapshotStore.kt',
    ROOT / 'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidBrowserCookieSession.kt',
    ROOT / 'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCookieJar.kt',
    ROOT / 'packages/network_bridge/android/src/main/kotlin/dev/zic/network/NetworkBrowserActivity.kt',
    ROOT / 'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidWebViewProcess.kt',
)


def main() -> int:
    kotlinc = shutil.which('kotlinc')
    javac = shutil.which('javac')
    if not kotlinc or not javac:
        print('SKIP: kotlinc/javac are unavailable for external login bridge compilation')
        return 0

    java_sources = {
                'android/content/Intent.java': '''package android.content; public class Intent { public String getStringExtra(String key){ return null; } public boolean getBooleanExtra(String key,boolean fallback){ return fallback; } public Intent putExtra(String key,String value){ return this; } public Intent putExtra(String key,boolean value){ return this; } }''',
        'android/content/Context.java': '''package android.content; import java.io.File; public class Context { public File getFilesDir(){ return new File("."); } public Context getApplicationContext(){ return this; } }''',
        'android/os/Bundle.java': '''package android.os; public class Bundle {}''',
        'android/os/Looper.java': '''package android.os; public class Looper { public static Looper getMainLooper(){ return new Looper(); } }''',
        'android/os/Handler.java': '''package android.os; public class Handler { public Handler(Looper looper){} public boolean postDelayed(Runnable r,long delay){ return true; } public void removeCallbacksAndMessages(Object token){} }''',
        'android/os/SystemClock.java': '''package android.os; public class SystemClock { public static long uptimeMillis(){ return 0L; } }''',
        'android/graphics/Bitmap.java': '''package android.graphics; public class Bitmap {}''',
        'android/os/Build.java': '''package android.os; public class Build { public static class VERSION { public static int SDK_INT=35; } public static class VERSION_CODES { public static final int P=28; } }''',
        'android/app/Activity.java': '''package android.app; import android.content.Context; import android.content.Intent; import android.os.Bundle; public class Activity extends Context { public static final int RESULT_CANCELED=0; public static final int RESULT_OK=-1; public static final int RESULT_FIRST_USER=1; public Intent getIntent(){ return new Intent(); } protected void onCreate(Bundle state){} protected void onDestroy(){} public void onBackPressed(){} public void finish(){} public void setResult(int code){} public void setResult(int code,Intent data){} public void setContentView(Object view){} public boolean isFinishing(){ return false; } public boolean isDestroyed(){ return false; } }''',
        'android/view/ViewGroup.java': '''package android.view; public class ViewGroup { public static class LayoutParams { public static final int MATCH_PARENT=-1; public LayoutParams(int width,int height){} } }''',
        'android/webkit/ValueCallback.java': '''package android.webkit; public interface ValueCallback<T>{ void onReceiveValue(T value); }''',
        'android/webkit/WebSettings.java': '''package android.webkit; public class WebSettings { public boolean getJavaScriptEnabled(){return false;} public void setJavaScriptEnabled(boolean value){} public boolean getDomStorageEnabled(){return false;} public void setDomStorageEnabled(boolean value){} public boolean getDatabaseEnabled(){return false;} public void setDatabaseEnabled(boolean value){} public String getUserAgentString(){return "";} public void setUserAgentString(String value){} }''',
        'android/webkit/WebViewClient.java': '''package android.webkit; public class WebViewClient { public void onPageStarted(WebView view,String url,android.graphics.Bitmap favicon){} public void onPageFinished(WebView view,String url){} }''',
        'android/webkit/WebView.java': '''package android.webkit; import android.content.Context; import android.view.ViewGroup; public class WebView { public WebView(Context context){} public ViewGroup.LayoutParams getLayoutParams(){return null;} public void setLayoutParams(ViewGroup.LayoutParams value){} public WebSettings getSettings(){ return new WebSettings(); } public WebViewClient getWebViewClient(){return null;} public void setWebViewClient(WebViewClient value){} public String getTitle(){ return ""; } public String getUrl(){ return ""; } public int getProgress(){ return 100; } public void loadUrl(String url){} public boolean canGoBack(){ return false; } public void goBack(){} public void evaluateJavascript(String script, ValueCallback<String> callback){ callback.onReceiveValue("null"); } public void stopLoading(){} public void destroy(){} public static void setDataDirectorySuffix(String suffix){} }''',
        'android/webkit/CookieManager.java': '''package android.webkit; public class CookieManager { private static final CookieManager INSTANCE=new CookieManager(); public static CookieManager getInstance(){ return INSTANCE; } public String getCookie(String url){ return ""; } public void setCookie(String url,String value){} public void setCookie(String url,String value,ValueCallback<Boolean> callback){ callback.onReceiveValue(true); } public void setAcceptCookie(boolean value){} public void setAcceptThirdPartyCookies(WebView view,boolean value){} public void flush(){} }''',
        'okhttp3/HttpUrl.java': '''package okhttp3; public class HttpUrl { public String getEncodedPath(){ return "/"; } public String toString(){ return "https://example.invalid/"; } }''',
        'okhttp3/Cookie.java': '''package okhttp3; public class Cookie { public static Cookie parse(HttpUrl url,String value){ return new Cookie(); } public String getName(){ return "a"; } public String getPath(){ return "/"; } public String getDomain(){ return "example.invalid"; } public boolean getHostOnly(){ return true; } public long getExpiresAt(){ return Long.MAX_VALUE; } public boolean matches(HttpUrl url){ return true; } public String toString(){ return "a=b"; } }''',
        'okhttp3/CookieJar.java': '''package okhttp3; import java.util.List; public interface CookieJar { void saveFromResponse(HttpUrl url,List<Cookie> cookies); List<Cookie> loadForRequest(HttpUrl url); }''',
        'org/json/JSONObject.java': '''package org.json; import java.util.Collections; import java.util.Iterator; public class JSONObject { public static final Object NULL=new Object(); public JSONObject(){} public JSONObject(String raw){} public JSONObject put(String key,Object value){ return this; } public String optString(String key){ return ""; } public long optLong(String key,long fallback){ return fallback; } public Iterator<String> keys(){ return Collections.<String>emptyList().iterator(); } public Object opt(String key){ return null; } public String toString(){ return "{}"; } }''',
        'org/json/JSONArray.java': '''package org.json; public class JSONArray { public JSONArray(String raw){} public String optString(int index){ return ""; } public boolean optBoolean(int index,boolean fallback){ return fallback; } }''',
    }

    with tempfile.TemporaryDirectory() as raw:
        temp = Path(raw)
        classes = temp / 'classes'
        classes.mkdir()
        paths: list[str] = []
        for relative, text in java_sources.items():
            path = temp / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            paths.append(str(path))
        subprocess.run([javac, '-d', str(classes), *paths], check=True)
        subprocess.run(
            [kotlinc, *(str(path) for path in SOURCES), '-classpath', str(classes), '-d', str(temp / 'out.jar')],
            check=True,
        )
    print('Shared network browser bridge compilation: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
