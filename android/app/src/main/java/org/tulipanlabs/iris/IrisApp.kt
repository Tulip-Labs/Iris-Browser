package org.tulipanlabs.iris

import android.app.Application

/**
 * Iris for Android: pages by Chromium built into the app (Cefrium, CEF for
 * Android), the interface in Jetpack Compose drawn as Liquid Glass.
 */
class IrisApp : Application() {
    override fun onCreate() {
        super.onCreate()
        instance = this
        Store.init(this)
        Shields.init(filesDir) { Shields.gunzipAsset { assets.open("shield-domains.json.gz") } }
    }

    companion object {
        lateinit var instance: IrisApp
            private set
    }
}
