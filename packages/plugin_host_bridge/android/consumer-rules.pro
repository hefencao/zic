# Mihon extension APKs and their versioned Source ABI are loaded from private
# read-only dex assets after the App has been built. R8 cannot see the dynamic
# APK references to host-provided common libraries, so retain those names and
# callable members in minified release builds. The Tachiyomi Source API,
# NetworkHelper, and Injekt live together in the functional ABI asset.
# AndroidX Preference remains a common provider so its classes and resources
# are merged exactly once.
-keepattributes Signature,InnerClasses,EnclosingMethod,*Annotation*
-keep,allowoptimization class kotlin.** { *; }
-keep,allowoptimization class androidx.preference.** { *; }
-keep,allowoptimization class rx.** { *; }
-keep,allowoptimization class kotlinx.coroutines.** { *; }
-keep,allowoptimization class kotlinx.serialization.** { *; }
-keep,allowoptimization class okhttp3.** { *; }
-keep,allowoptimization class okio.** { *; }
-keep,allowoptimization class org.jsoup.** { *; }
-keep,allowoptimization class com.google.gson.** { *; }
-keep,allowoptimization class com.squareup.zstd.** { *; }
-keep,allowoptimization class com.github.zhanghai.quickjs.** { *; }
