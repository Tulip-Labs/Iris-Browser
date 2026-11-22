package org.tulipanlabs.iris

import android.app.Application

/**
 * Iris for Android: pages by Android System WebView (Chromium, kept up to
 * date by the phone), the interface in Jetpack Compose drawn as Liquid Glass.
 */
class IrisApp : Application() {
    override fun onCreate() {
        super.onCreate()
        instance = this
        // the sandbox's own process: WebView data of its own, made fresh
        if (Application.getProcessName().endsWith(":" + SandboxActivity.PROCESS_SUFFIX)) {
            SandboxActivity.wipe(this)
            android.webkit.WebView.setDataDirectorySuffix(SandboxActivity.PROCESS_SUFFIX)
        }
        Store.init(this)
        Shields.init(filesDir) { Shields.gunzipAsset { assets.open("shield-domains.json.gz") } }
    }

    companion object {
        lateinit var instance: IrisApp
            private set
    }
}
