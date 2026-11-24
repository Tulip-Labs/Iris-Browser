package org.tulipanlabs.iris

import android.app.Application

/**
 * Iris for Android: pages by Cefrium (its own Chromium), the interface in
 * Jetpack Compose drawn as Liquid Glass.
 */
class IrisApp : Application() {
    override fun onCreate() {
        super.onCreate()
        instance = this
        // Cefrium's renderer processes run this too, and Store and Shields
        // fail there, so the renderer dies and the page stays blank (issue
        // #24, diagnosed by vejeta, the Cefrium maintainer): leave at once.
        // The sandbox's own process (:sandbox) is not one of these.
        val process = Application.getProcessName()
        if (Regex(".*:(sandboxed|privileged)_process\\d+(:.*)?").matches(process)) return
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
