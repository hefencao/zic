# Mihon extension APKs and their versioned Source ABI are loaded from private
# read-only dex assets after the App has been built. R8 cannot see the dynamic
# APK references to host-provided common libraries, so retain those names and
# callable members in minified release builds. The Tachiyomi Source API classes live in the child-first ABI asset.
# AndroidX Preference remains a parent common provider so its classes and
# resources are merged exactly once.
-keepattributes Signature,InnerClasses,EnclosingMethod,*Annotation*
-keep,allowoptimization class androidx.preference.** { *; }
-keep,allowoptimization class uy.kohesive.injekt.** { *; }
-keep,allowoptimization class io.reactivex.** { *; }
-keep,allowoptimization class kotlinx.coroutines.** { *; }
-keep,allowoptimization class kotlinx.serialization.** { *; }
-keep,allowoptimization class okhttp3.** { *; }
-keep,allowoptimization class okio.** { *; }
-keep,allowoptimization class org.jsoup.** { *; }
-keep,allowoptimization class com.google.gson.** { *; }
-keep,allowoptimization class com.squareup.zstd.** { *; }
-keep,allowoptimization class com.github.zhanghai.quickjs.** { *; }
