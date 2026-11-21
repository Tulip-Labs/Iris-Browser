package org.tulipanlabs.iris

import android.app.Application

/**
 * Iris for Android: pages by Android System WebView (Chromium, kept up to
 * date by the phone), the interface in Jetpack Compose and Material 3.
 */
class IrisApp : Application() {
    override fun onCreate() {
        super.onCreate()
        instance = this
        Store.init(this)
        Shields.load(this)
    }

    companion object {
        lateinit var instance: IrisApp
            private set
    }
}
