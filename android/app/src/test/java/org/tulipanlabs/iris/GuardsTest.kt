package org.tulipanlabs.iris

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** what Iris lets in from outside: links from other apps, downloads, updates */
class GuardsTest {
    @Test fun linksFromOtherApps() {
        assertEquals("https://example.com/a", Search.external("https://example.com/a"))
        assertEquals("http://example.com", Search.external(" http://example.com "))
        assertNull(Search.external("javascript:alert(1)"))
        assertNull(Search.external("file:///data/data/org.tulipanlabs.lite/shared_prefs/x.xml"))
        assertNull(Search.external("intent://x#Intent;scheme=http;end"))
        assertNull(Search.external("content://downloads/1"))
        assertNull(Search.external("https://"))
    }

    @Test fun addressBar() {
        assertEquals("https://example.com", Search.resolve("example.com"))
        assertEquals("http://localhost:8080", Search.resolve("localhost:8080"))
        assertTrue(Search.resolve("javascript:alert(1)").contains("udm=50"))
        assertEquals("why is the sky blue", Search.query(Search.aiUrl("why is the sky blue")))
        assertTrue(Search.untrusted("http://example.com/"))
        assertFalse(Search.untrusted("https://example.com/"))
        assertFalse(Search.untrusted("http://192.168.1.1/"))
    }

    @Test fun downloadsOnlyFromTheWeb() {
        assertTrue(Downloads.isWeb("https://example.com/a.pdf"))
        assertTrue(Downloads.isWeb("http://example.com/a.pdf"))
        assertFalse(Downloads.isWeb("file:///data/data/org.tulipanlabs.lite/databases/x"))
        assertFalse(Downloads.isWeb("content://media/external/1"))
        assertFalse(Downloads.isWeb("ftp://example.com/a"))
        assertFalse(Downloads.isWeb("not a url"))
    }

    @Test fun updatesOnlyFromIrisReleases() {
        assertTrue(Updater.fromGitHub("https://github.com/Tulip-Labs/Iris-Browser/releases/download/v2.2.4/Iris-android.apk"))
        assertFalse(Updater.fromGitHub("http://github.com/Tulip-Labs/Iris-Browser/releases/download/v2.2.4/Iris-android.apk"))
        assertFalse(Updater.fromGitHub("https://github.com/someone/else/releases/download/v9/Iris-android.apk"))
        assertFalse(Updater.fromGitHub("https://github.com.evil.example/Tulip-Labs/Iris-Browser/releases/download/v9/x.apk"))
        assertEquals("Iris-android-cefrium.apk", Updater.apkName("cefrium"))
        assertEquals("Iris-android.apk", Updater.apkName("webview"))
        assertTrue(Updater.newer("2.2.10", "2.2.9"))
        assertFalse(Updater.newer("2.2.3", "2.2.3"))
        assertFalse(Updater.newer("2.2", "2.2.0"))
    }
}
