plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "org.tulipanlabs.iris"
    compileSdk = 36

    defaultConfig {
        // the id stays, so Iris installs over earlier versions
        applicationId = "org.tulipanlabs.lite"
        minSdk = 29
        targetSdk = 36
        versionCode = 201
        versionName = "2.0.1"
    }

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
        release {
            isMinifyEnabled = false
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

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

dependencies {
    // the page engine is Android System WebView (Chromium, kept up to date
    // by the phone); androidx.webkit adds profiles (containers) and more
    implementation("androidx.webkit:webkit:1.13.0")
    implementation("androidx.swiperefreshlayout:swiperefreshlayout:1.1.0")

    val compose = platform("androidx.compose:compose-bom:2025.06.00")
    implementation(compose)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.1")
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}
