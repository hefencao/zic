#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    ROOT / 'packages/network_bridge/android/src/main/kotlin/dev/zic/network/NetworkBrowserSnapshotStore.kt',
    ROOT / 'packages/network_bridge/android/src/main/kotlin/dev/zic/network/NetworkBrowserActivity.kt',
)


def main() -> int:
    kotlinc = shutil.which('kotlinc')
    javac = shutil.which('javac')
    if not kotlinc or not javac:
        print('SKIP: kotlinc/javac are unavailable for external login bridge compilation')
        return 0

    java_sources = {
                'android/content/Intent.java': '''package android.content; public class Intent { public String getStringExtra(String key){ return null; } }''',
        'android/content/Context.java': '''package android.content; import java.io.File; public class Context { public File getFilesDir(){ return new File("."); } }''',
        'android/os/Bundle.java': '''package android.os; public class Bundle {}''',
        'android/app/Activity.java': '''package android.app; import android.content.Context; import android.content.Intent; import android.os.Bundle; public class Activity extends Context { public Intent getIntent(){ return new Intent(); } protected void onCreate(Bundle state){} protected void onDestroy(){} public void onBackPressed(){} public void finish(){} public void setContentView(Object view){} }''',
        'android/view/ViewGroup.java': '''package android.view; public class ViewGroup { public static class LayoutParams { public static final int MATCH_PARENT=-1; public LayoutParams(int width,int height){} } }''',
        'android/webkit/ValueCallback.java': '''package android.webkit; public interface ValueCallback<T>{ void onReceiveValue(T value); }''',
        'android/webkit/WebSettings.java': '''package android.webkit; public class WebSettings { public boolean getJavaScriptEnabled(){return false;} public void setJavaScriptEnabled(boolean value){} public boolean getDomStorageEnabled(){return false;} public void setDomStorageEnabled(boolean value){} public boolean getDatabaseEnabled(){return false;} public void setDatabaseEnabled(boolean value){} }''',
        'android/webkit/WebViewClient.java': '''package android.webkit; public class WebViewClient { public void onPageFinished(WebView view,String url){} }''',
        'android/webkit/WebView.java': '''package android.webkit; import android.content.Context; import android.view.ViewGroup; public class WebView { public WebView(Context context){} public ViewGroup.LayoutParams getLayoutParams(){return null;} public void setLayoutParams(ViewGroup.LayoutParams value){} public WebSettings getSettings(){ return new WebSettings(); } public WebViewClient getWebViewClient(){return null;} public void setWebViewClient(WebViewClient value){} public String getTitle(){ return ""; } public String getUrl(){ return ""; } public void loadUrl(String url){} public boolean canGoBack(){ return false; } public void goBack(){} public void evaluateJavascript(String script, ValueCallback<String> callback){ callback.onReceiveValue("null"); } public void stopLoading(){} public void destroy(){} }''',
        'android/webkit/CookieManager.java': '''package android.webkit; public class CookieManager { private static final CookieManager INSTANCE=new CookieManager(); public static CookieManager getInstance(){ return INSTANCE; } public String getCookie(String url){ return ""; } public void setAcceptCookie(boolean value){} public void setAcceptThirdPartyCookies(WebView view,boolean value){} public void flush(){} }''',
        'org/json/JSONObject.java': '''package org.json; import java.util.Collections; import java.util.Iterator; public class JSONObject { public static final Object NULL=new Object(); public JSONObject(){} public JSONObject(String raw){} public JSONObject put(String key,Object value){ return this; } public String optString(String key){ return ""; } public long optLong(String key,long fallback){ return fallback; } public Iterator<String> keys(){ return Collections.<String>emptyList().iterator(); } public Object opt(String key){ return null; } public String toString(){ return "{}"; } }''',
        'org/json/JSONArray.java': '''package org.json; public class JSONArray { public JSONArray(String raw){} public String optString(int index){ return ""; } }''',
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
