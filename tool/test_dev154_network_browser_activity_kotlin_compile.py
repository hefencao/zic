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
        'android/content/Intent.java': '''package android.content; public class Intent { private final java.util.Map<String,Object> values=new java.util.HashMap<>(); public Intent(){} public String getStringExtra(String k){return (String)values.get(k);} public boolean getBooleanExtra(String k,boolean d){return values.containsKey(k)?(Boolean)values.get(k):d;} public Intent putExtra(String k,String v){values.put(k,v);return this;} public Intent putExtra(String k,boolean v){values.put(k,v);return this;} }''',
        'android/os/Bundle.java': '''package android.os; public class Bundle {}''',
        'android/os/Looper.java': '''package android.os; public class Looper { public static Looper getMainLooper(){ return new Looper(); } }''',
        'android/os/Handler.java': '''package android.os; public class Handler { public Handler(Looper l){} public boolean postDelayed(Runnable r,long d){ return true; } public void removeCallbacksAndMessages(Object token){} }''',
        'android/os/SystemClock.java': '''package android.os; public class SystemClock { public static long uptimeMillis(){ return 0L; } }''',
        'android/graphics/Bitmap.java': '''package android.graphics; public class Bitmap {}''',
        'android/view/ViewGroup.java': '''package android.view; public class ViewGroup { public static class LayoutParams { public static final int MATCH_PARENT=-1; public LayoutParams(int w,int h){} } }''',
        'android/webkit/ValueCallback.java': '''package android.webkit; public interface ValueCallback<T> { void onReceiveValue(T value); }''',
        'android/webkit/WebSettings.java': '''package android.webkit; public class WebSettings { public void setJavaScriptEnabled(boolean v){} public boolean getJavaScriptEnabled(){return true;} public void setDomStorageEnabled(boolean v){} public boolean getDomStorageEnabled(){return true;} public void setDatabaseEnabled(boolean v){} public boolean getDatabaseEnabled(){return true;} public void setUserAgentString(String v){} public String getUserAgentString(){return "ua";} }''',
        'android/webkit/WebViewClient.java': '''package android.webkit; public class WebViewClient { public void onPageStarted(WebView v,String u,android.graphics.Bitmap b){} public void onPageFinished(WebView v,String u){} }''',
        'android/webkit/WebView.java': '''package android.webkit; public class WebView {
 public static WebView last; private String url; private int progress;
 private final WebSettings settings=new WebSettings(); private WebViewClient client;
 public boolean deferJavascript=false; private final java.util.List<ValueCallback<String>> callbacks=new java.util.ArrayList<>();
 public WebView(android.content.Context c){last=this;} public void setLayoutParams(android.view.ViewGroup.LayoutParams p){} public android.view.ViewGroup.LayoutParams getLayoutParams(){return null;}
 public WebSettings getSettings(){return settings;} public void setWebViewClient(WebViewClient c){client=c;} public WebViewClient getWebViewClient(){return client;}
 public void loadUrl(String u){url=u;progress=0;client.onPageStarted(this,u,null);} public String getUrl(){return url;} public int getProgress(){return progress;}
 public void finishPage(){progress=100;client.onPageFinished(this,url);} public void evaluateJavascript(String s,ValueCallback<String> c){if(deferJavascript)callbacks.add(c);else c.onReceiveValue("[true,false]");}
 public void deliverJavascript(){for(ValueCallback<String> c:callbacks)c.onReceiveValue("[true,false]");callbacks.clear();}
 public String getTitle(){return "title";} public boolean canGoBack(){return false;} public void goBack(){} public void stopLoading(){} public void destroy(){} }''',
        'android/webkit/CookieManager.java': '''package android.webkit; public class CookieManager { private static final CookieManager I=new CookieManager(); public static CookieManager getInstance(){return I;} public void setAcceptCookie(boolean v){} public void setAcceptThirdPartyCookies(WebView v,boolean a){} public String getCookie(String u){return "session=x";} public void flush(){} }''',
        'android/app/Activity.java': '''package android.app; public class Activity extends android.content.Context { public static final int RESULT_CANCELED=0, RESULT_OK=-1, RESULT_FIRST_USER=1; private final android.content.Intent intent=new android.content.Intent(); private boolean finishing=false,destroyed=false; protected void onCreate(android.os.Bundle b){} public android.content.Intent getIntent(){return intent;} public void setResult(int r){} public void setResult(int r,android.content.Intent i){} public void setContentView(Object v){} public void finish(){finishing=true;} public boolean isFinishing(){return finishing;} public boolean isDestroyed(){return destroyed;} public void onBackPressed(){} protected void onDestroy(){destroyed=true;} }''',
        'org/json/JSONArray.java': '''package org.json; public class JSONArray {
 private final String[] values; public JSONArray(String s){if(!s.startsWith("[")||!s.endsWith("]"))throw new IllegalArgumentException();values=s.substring(1,s.length()-1).split(",");}
 public String optString(int i){return i<values.length?values[i].trim():"";} public boolean optBoolean(int i,boolean d){if(i>=values.length)return d;String v=values[i].trim();return v.equals("true")?true:v.equals("false")?false:d;} }''',
    }
    kotlin_support = '''package dev.zic.network
internal object NetworkBrowserSnapshotStore {
 var captures = 0
 fun begin(context: android.content.Context, requestedUrl: String, userAgent: String?) {}
 fun update(context: android.content.Context, currentUrl: String, title: String?, cookieHeader: String?, localStorageJson: String? = null, userAgent: String? = null) { captures++ }
}
'''
    behavior_probe = '''package dev.zic.network
fun main() {
 fun create(verification: Boolean = false): NetworkBrowserActivity {
  val activity = NetworkBrowserActivity()
  activity.intent.putExtra("url", "https://18comic.vip/")
   .putExtra("cloudflareVerification", verification)
  NetworkBrowserActivity::class.java.getDeclaredMethod("onCreate", android.os.Bundle::class.java)
   .apply { isAccessible = true }.invoke(activity, null)
  NetworkBrowserSnapshotStore.captures = 0
  return activity
 }
 fun destroy(activity: NetworkBrowserActivity) {
  NetworkBrowserActivity::class.java.getDeclaredMethod("onDestroy")
   .apply { isAccessible = true }.invoke(activity)
 }
 val parser = NetworkBrowserActivity::class.java.getDeclaredMethod("parseBrowserVerificationState", String::class.java)
  .apply { isAccessible = true }
 fun parsed(raw: String, field: String): Boolean {
  val result = parser.invoke(NetworkBrowserActivity(), raw)
  return result.javaClass.getDeclaredField(field).apply { isAccessible = true }.getBoolean(result)
 }
 check(parsed("[true,false]", "ready")) { "completed JS boolean was not ready" }
 check(!parsed("[false,false]", "ready")) { "incomplete JS state was ready" }
 check(parsed("[true,true]", "challengeVisible")) { "visible challenge was lost" }
 check(!parsed("invalid", "ready") && parsed("invalid", "challengeVisible")) { "invalid probe did not retain verification" }
 val cancelled = create()
 cancelled.onBackPressed()
 destroy(cancelled)
 check(NetworkBrowserSnapshotStore.captures == 0) { "unfinished Back advanced snapshot revision" }
 val interrupted = create()
 destroy(interrupted)
 check(NetworkBrowserSnapshotStore.captures == 0) { "unfinished Activity destruction captured a page" }
 val navigated = create()
 android.webkit.WebView.last.finishPage()
 check(NetworkBrowserSnapshotStore.captures > 0) { "completed ordinary page lost capture" }
 val beforeNavigation = NetworkBrowserSnapshotStore.captures
 android.webkit.WebView.last.loadUrl("https://18comic.vip/next")
 navigated.onBackPressed()
 destroy(navigated)
 check(NetworkBrowserSnapshotStore.captures == beforeNavigation) { "pending next navigation replaced completed capture" }
 val verification = create(true)
 android.webkit.WebView.last.finishPage()
 verification.onBackPressed()
 destroy(verification)
 check(NetworkBrowserSnapshotStore.captures == 0) { "unresolved verification captured before stable success" }
 val delayed = create()
 android.webkit.WebView.last.deferJavascript = true
 android.webkit.WebView.last.finishPage()
 val beforeLate = NetworkBrowserSnapshotStore.captures
 android.webkit.WebView.last.loadUrl("https://18comic.vip/next")
 android.webkit.WebView.last.deliverJavascript()
 check(NetworkBrowserSnapshotStore.captures == beforeLate) { "stale localStorage callback changed a newer navigation" }
 destroy(delayed)
 val completed = create()
 val oldView = android.webkit.WebView.last
 oldView.finishPage()
 completed.onBackPressed()
 check(completed.isFinishing) { "completed capture did not close browser" }
 val next = create()
 destroy(completed)
 check(NetworkBrowserSnapshotStore.captures == 0) { "completed old Activity updated next browser handoff" }
 destroy(next)
 val closing = create()
 android.webkit.WebView.last.finishPage()
 android.webkit.WebView.last.deferJavascript = true
 closing.onBackPressed()
 check(!closing.isFinishing) { "browser returned before localStorage capture" }
 android.webkit.WebView.last.deliverJavascript()
 check(closing.isFinishing) { "complete capture did not release browser result" }
 destroy(closing)
 println("browser capture lifecycle: 7 cases and 4 probe states passed")
}
'''

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
        probe = temp / 'BrowserCaptureProbe.kt'
        probe.write_text(behavior_probe, encoding='utf-8')
        output = temp / 'activity.jar'
        subprocess.run(
            [
                kotlinc,
                str(ACTIVITY),
                str(support),
                str(probe),
                '-classpath',
                str(classes),
                '-d',
                str(output),
            ],
            check=True,
        )
        subprocess.run(['kotlin', '-classpath', f'{output}:{classes}',
            'dev.zic.network.BrowserCaptureProbeKt'], check=True)
    print('dev.154 NetworkBrowserActivity Kotlin compile: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
