# Mihon extension APKs are loaded after the App has been built. R8 cannot see
# their bytecode references, so the host-provided ABI and common runtime must
# retain binary names and callable members in minified release builds.
-keepattributes Signature,InnerClasses,EnclosingMethod,*Annotation*
-keep,allowoptimization class eu.kanade.tachiyomi.** { *; }
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
