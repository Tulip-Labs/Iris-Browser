plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    // Cefrium's plugin: it makes the Chromium resource classes the SDK
    // needs. Iris carries its own Chromium (CEF) now, so the plugin
    // applies to every build.
    id("com.cefrium") version "0.21.0"
}

android {
    namespace = "org.tulipanlabs.iris"
    compileSdk = 36

    defaultConfig {
        // the id stays, so Iris installs over earlier versions
        applicationId = "org.tulipanlabs.lite"
        minSdk = 29
        targetSdk = 36
        versionCode = 226
        versionName = "2.2.6"
    }

    // One Android build, on Cefrium: its own Chromium (CEF), the same
    // engine on every phone. The WebView build is gone (2.2.6): its typing
    // broke in 2.2.5, and Cefrium is the engine that works.

    signingConfigs {
        // Updates install over the app only when every APK is signed with
        // the same key: CI signs with the key in the repository's secrets
        // (IRIS_KEYSTORE, base64, and its passwords)
        create("release") {
            val ks = System.getenv("IRIS_KEYSTORE_FILE")
            if (ks != null && file(ks).exists()) {
                storeFile = file(ks)
                storePassword = System.getenv("IRIS_KEYSTORE_PASSWORD")
                // CI passes unset secrets as empty strings
                keyAlias = System.getenv("IRIS_KEY_ALIAS")?.takeIf { it.isNotEmpty() } ?: "iris"
                keyPassword = System.getenv("IRIS_KEY_PASSWORD")?.takeIf { it.isNotEmpty() } ?: System.getenv("IRIS_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        debug {
            // the emulator runs x86_64; a phone runs arm64
            ndk { abiFilters += listOf("x86_64", "arm64-v8a") }
        }
        release {
            // no shrinking: Iris's own code is small, and the pages are
            // drawn by an engine, not by the app
            isMinifyEnabled = false
            // one architecture, as in 1.0.24: the release APK stays small
            ndk { abiFilters += "arm64-v8a" }
            val rel = signingConfigs.getByName("release")
            signingConfig = if (rel.storeFile != null) rel else signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // the unit tests run on the computer, not a phone: Android's own
    // classes answer with defaults there
    testOptions { unitTests.isReturnDefaultValues = true }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
        // Cefrium's Chromium reads its libraries from the disk, not from
        // the APK's compressed entries
        jniLibs { useLegacyPackaging = true }
    }
}

dependencies {
    // the page engine: its own Chromium (CEF) through Cefrium 0.21.0
    // (Chromium 156.0.8078.96), the same engine on every phone
    implementation("com.cefrium:cefrium-sdk:0.21.0")

    // the interface: Compose's foundation only, drawn as Liquid Glass (no
    // Material components)
    val compose = platform("androidx.compose:compose-bom:2025.06.00")
    implementation(compose)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.1")
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    testImplementation("junit:junit:4.13.2")
}
