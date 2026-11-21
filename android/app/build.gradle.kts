import java.net.URI
import java.util.zip.ZipInputStream

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// uBlock Origin, built into Iris as the engine of its Shields (Firefox's
// own extension, run by GeckoView): fetched at build time, unpacked into
// the APK's assets
val ublockVersion = "1.76.6"
val ublockDir = layout.buildDirectory.dir("generated/ublock")
val fetchUblock by tasks.registering {
    val out = ublockDir
    inputs.property("version", ublockVersion)
    outputs.dir(out)
    doLast {
        val dest = out.get().dir("extensions/ublock").asFile
        dest.deleteRecursively()
        dest.mkdirs()
        val url = "https://github.com/gorhill/uBlock/releases/download/$ublockVersion/uBlock0_$ublockVersion.firefox.signed.xpi"
        URI(url).toURL().openStream().use { raw ->
            ZipInputStream(raw).use { zip ->
                while (true) {
                    val e = zip.nextEntry ?: break
                    val f = File(dest, e.name).canonicalFile
                    require(f.path.startsWith(dest.canonicalPath)) { "bad entry ${e.name}" }
                    if (e.isDirectory) f.mkdirs() else { f.parentFile.mkdirs(); f.outputStream().use { zip.copyTo(it) } }
                }
            }
        }
    }
}

android {
    namespace = "org.tulipanlabs.iris"
    compileSdk = 36

    defaultConfig {
        // the id stays, so Iris installs over earlier versions
        applicationId = "org.tulipanlabs.lite"
        minSdk = 29
        targetSdk = 36
        versionCode = 200
        versionName = "2.0.0"
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
                keyAlias = System.getenv("IRIS_KEY_ALIAS") ?: "iris"
                keyPassword = System.getenv("IRIS_KEY_PASSWORD") ?: System.getenv("IRIS_KEYSTORE_PASSWORD")
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

    // a plain path (AGP 9 takes no Provider here); preBuild runs fetchUblock first
    sourceSets.getByName("main").assets.directories.add(ublockDir.get().asFile.path)

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

tasks.named("preBuild") { dependsOn(fetchUblock) }

dependencies {
    // the page engine: GeckoView, Firefox for Android's engine
    implementation("org.mozilla.geckoview:geckoview:160.+")

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
