plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "org.tulipanlabs.lite"
    compileSdk = 35

    defaultConfig {
        applicationId = "org.tulipanlabs.lite"
        minSdk = 26
        targetSdk = 35
        versionCode = 2
        versionName = "1.0.2"
    }

    buildTypes {
        release {
            // smaller and faster: unused code and resources are removed
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // signed with this PC's debug key, to install for testing; use your own key for the Play Store
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

dependencies {
    // only for scripts that run before a page's own (YouTube without ads, fingerprinting protection)
    implementation("androidx.webkit:webkit:1.12.1")
}
