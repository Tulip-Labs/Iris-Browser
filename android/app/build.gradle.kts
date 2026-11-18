plugins {
    id("com.android.application")
    id("com.cefrium") version "0.21.0"
}

android {
    namespace = "org.tulipanlabs.lite"
    compileSdk = 37 // what Cefrium is built against

    defaultConfig {
        // the id stays, so Iris installs over Lite and keeps its tabs and settings
        applicationId = "org.tulipanlabs.lite"
        minSdk = 29 // Cefrium's Chromium needs Android 10
        targetSdk = 35
        versionCode = 20
        versionName = "1.0.21"
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        debug {
            // the emulator (screenshots) and phones
            ndk { abiFilters += listOf("x86_64", "arm64-v8a") }
        }
        release {
            // phones: 64-bit ARM only, so the APK carries one Chromium
            ndk { abiFilters += listOf("arm64-v8a") }
            // no shrinking: the app is mostly Chromium, which R8 cannot shrink
            // safely (its resources and native calls), and Iris's own code is small
            isMinifyEnabled = false
            isShrinkResources = false
            // signed with this PC's debug key, to install for testing; use your own key for the Play Store
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

dependencies {
    // the page engine: Chromium (CEF) built for Android, with H.264 and AAC
    implementation("com.cefrium:cefrium-sdk:0.21.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.mediarouter:mediarouter:1.7.0")
    implementation("androidx.core:core:1.16.0")
    implementation("androidx.browser:browser:1.8.0")
}
