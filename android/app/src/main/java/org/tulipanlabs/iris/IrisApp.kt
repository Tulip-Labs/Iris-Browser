package org.tulipanlabs.iris

import android.app.Application
import android.util.Log
import org.mozilla.geckoview.ContentBlocking
import org.mozilla.geckoview.GeckoRuntime
import org.mozilla.geckoview.GeckoRuntimeSettings
import org.mozilla.geckoview.WebExtension

/**
 * Iris for Android. One GeckoRuntime for the whole app (GeckoView allows a
 * single one per process); every tab's GeckoSession runs in it.
 */
class IrisApp : Application() {
    lateinit var runtime: GeckoRuntime
        private set

    /** uBlock Origin, once GeckoView has it running */
    var ublock: WebExtension? = null
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this
        Store.init(this)
        runtime = GeckoRuntime.create(this, settings())
        // Iris Shields: Firefox's strict tracking protection inside the
        // engine, and uBlock Origin built in for ads, pop-ups and cosmetic
        // filtering (the lists Brave Shields uses too: EasyList, EasyPrivacy,
        // uBlock's own and Peter Lowe's)
        runtime.webExtensionController
            .ensureBuiltIn("resource://android/assets/extensions/ublock/", UBLOCK_ID)
            .accept({ ext -> ublock = ext }, { e -> Log.w("Iris", "uBlock Origin did not start", e) })
    }

    private fun settings(): GeckoRuntimeSettings {
        val shields = Store.shields
        val blocking = ContentBlocking.Settings.Builder()
            .antiTracking(if (shields) ContentBlocking.AntiTracking.STRICT else ContentBlocking.AntiTracking.DEFAULT)
            .enhancedTrackingProtectionLevel(if (shields) ContentBlocking.EtpLevel.STRICT else ContentBlocking.EtpLevel.DEFAULT)
            // every site's cookies kept to itself (Total Cookie Protection)
            .cookieBehavior(ContentBlocking.CookieBehavior.ACCEPT_FIRST_PARTY_AND_ISOLATE_OTHERS)
            .cookieBannerHandlingMode(ContentBlocking.CookieBannerMode.COOKIE_BANNER_MODE_REJECT)
            .queryParameterStrippingEnabled(shields)
            .safeBrowsing(ContentBlocking.SafeBrowsing.DEFAULT)
            .build()
        return GeckoRuntimeSettings.Builder()
            .contentBlocking(blocking)
            .aboutConfigEnabled(false)
            .consoleOutput(BuildConfig.DEBUG)
            .build()
    }

    /** Shields everywhere on or off (tracking protection; uBlock follows) */
    fun applyShields(on: Boolean) {
        Store.shields = on
        val cb = runtime.settings.contentBlocking
        cb.setAntiTracking(if (on) ContentBlocking.AntiTracking.STRICT else ContentBlocking.AntiTracking.DEFAULT)
        cb.setEnhancedTrackingProtectionLevel(if (on) ContentBlocking.EtpLevel.STRICT else ContentBlocking.EtpLevel.DEFAULT)
        cb.setQueryParameterStrippingEnabled(on)
        ublock?.let { ext ->
            val c = runtime.webExtensionController
            if (on) c.enable(ext, org.mozilla.geckoview.WebExtensionController.EnableSource.USER)
            else c.disable(ext, org.mozilla.geckoview.WebExtensionController.EnableSource.USER)
        }
    }

    companion object {
        const val UBLOCK_ID = "uBlock0@raymondhill.net"
        lateinit var instance: IrisApp
            private set
    }
}
