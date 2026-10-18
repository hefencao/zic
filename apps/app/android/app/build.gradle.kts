import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val zicVersion = Properties().apply {
    val file = rootProject.file("zic-version.properties")
    check(file.isFile) { "Missing project-owned Android version file: $file" }
    file.inputStream().use(::load)
}
val zicVersionName = zicVersion.getProperty("versionName")
    ?.trim()
    ?.takeIf(String::isNotEmpty)
    ?: error("zic-version.properties is missing versionName")
val zicVersionCode = zicVersion.getProperty("versionCode")
    ?.trim()
    ?.toIntOrNull()
    ?.takeIf { it > 0 }
    ?: error("zic-version.properties has an invalid versionCode")

android {
    namespace = "dev.zic.zic"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.zic.zic"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // All run modes share one package version so switching
        // debug/profile/release never forces a downgrade uninstall.
        versionCode = zicVersionCode
        versionName = zicVersionName
    }

    packaging {
        jniLibs {
            // Compress in the APK; Android extracts once at installation so
            // native execution still loads the original library files.
            useLegacyPackaging = true
        }
    }

    buildTypes {
        configureEach {
            applicationIdSuffix = null
            versionNameSuffix = null
        }
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

val verifyZicNativeArtifacts by tasks.registering {
    group = "verification"
    description = "Rejects missing or stale source-built ZIC Android native libraries."
    doLast {
        val repositoryRoot = projectDir.resolve("../../../..").canonicalFile
        val expectedFile = repositoryRoot.resolve(
            "native/media_core/ANDROID_NATIVE_BUILD_ID",
        )
        val marker = projectDir.resolve("src/main/jniLibs/.zic-native-build-id")
        val expected = expectedFile.takeIf { it.isFile }?.readText()?.trim().orEmpty()
        val actual = marker.takeIf { it.isFile }?.readText()?.trim().orEmpty()
        check(expected.isNotEmpty()) {
            "Missing source Android native build ID: $expectedFile"
        }
        check(actual == expected) {
            "Android native artifacts are missing or stale. " +
                "Expected '$expected', found '${actual.ifEmpty { "<missing>" }}'. " +
                "Run ./tool/build_android_native.sh debug or release."
        }
        val configured = providers.environmentVariable("ZIC_ANDROID_ABIS")
            .orElse("arm64-v8a,armeabi-v7a,x86_64")
            .get()
            .split(',')
            .map(String::trim)
            .filter(String::isNotEmpty)
        for (abi in configured) {
            val library = projectDir.resolve(
                "src/main/jniLibs/$abi/libmedia_core.so",
            )
            check(library.isFile && library.length() > 0L) {
                "Missing source-built native media library: $library. " +
                    "Run ./tool/build_android_native.sh debug or release."
            }
        }
    }
}

tasks.named("preBuild").configure {
    dependsOn(verifyZicNativeArtifacts)
}

// SAF byte bridge: DocumentFile tree walking for user-chosen download
// directories (no storage permission; persisted tree grants only).
dependencies {
    implementation("androidx.documentfile:documentfile:1.0.1")
    testImplementation("junit:junit:4.13.2")
}
