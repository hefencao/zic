# Mihon extension APKs and their versioned Source ABI are loaded from private
# read-only dex assets after the App has been built. R8 cannot see the dynamic
# APK references to host-provided common libraries, so retain those names and
# callable members in minified release builds. The Tachiyomi Source API,
# NetworkHelper, and Injekt live together in the functional ABI asset.
# AndroidX Preference remains a common provider so its classes and resources
# are merged exactly once.
-keepattributes Signature,InnerClasses,EnclosingMethod,*Annotation*
# Do not allow whole-program optimization across this boundary. Dynamically
# loaded extension implementations are absent from R8's program graph. If
# optimization is allowed, R8 can devirtualize an interface call using only
# the App's visible implementations; for example, OkHttp CookieJar was
# specialized to NO_COOKIES and cast a valid extension ArrayList to EmptyList.
-keep class kotlin.** { *; }
-keep class androidx.preference.** { *; }
-keep class rx.** { *; }
-keep class kotlinx.coroutines.** { *; }
-keep class kotlinx.serialization.** { *; }
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep class org.jsoup.** { *; }
-keep class com.google.gson.** { *; }
-keep class com.squareup.zstd.** { *; }
-keep class com.github.zhanghai.quickjs.** { *; }
