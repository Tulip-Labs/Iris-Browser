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

    @Test fun everyFormOfAnAddressIsAnAddress() {
        // java.net.URI names no host for these; Chromium reads them as IPv4
        assertTrue(Search.untrusted("http://0xcb.0.113.7/"))
        assertTrue(Search.untrusted("https://0xcb.0.113.7/"))
        assertTrue(Search.untrusted("https://3405803783/"))
        assertTrue(Search.untrusted("https://203.0.113.7./"))
        assertTrue(Search.untrusted("https://user@3405803783:443/x"))
        assertFalse(Search.untrusted("http://127.1:8000/"))
        assertFalse(Search.untrusted("http://[::1]/"))
        assertFalse(Search.untrusted("https://1.2.3.4.example.com/"))
        assertEquals(listOf(127, 0, 0, 1), Search.ipv4("2130706433")?.toList())
        assertEquals(listOf(127, 0, 0, 1), Search.ipv4("0x7f.1")?.toList())
        assertEquals(listOf(8, 0, 0, 1), Search.ipv4("010.0.0.1")?.toList())
        assertEquals(listOf(10, 0, 255, 255), Search.ipv4("10.65535")?.toList())
        assertNull(Search.ipv4("256.1.1.1"))
        assertNull(Search.ipv4("1.2.3.4.5"))
        assertNull(Search.ipv4("1..2"))
        assertNull(Search.ipv4("4294967296"))
        assertNull(Search.ipv4("08.0.0.1"))
        assertNull(Search.ipv4("example.com"))
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
        assertEquals("Iris-android.apk", Updater.apkName())
        assertTrue(Updater.newer("2.2.10", "2.2.9"))
        assertFalse(Updater.newer("2.2.3", "2.2.3"))
        assertFalse(Updater.newer("2.2", "2.2.0"))
    }

    @Test fun sharedTextOpensWebLinksOnly() {
        assertEquals("https://example.com/a", Search.shared("Look at this: https://example.com/a."))
        assertEquals("https://example.com", Search.shared("example.com"))
        // a file: page could read Iris's own files: shared text never opens one
        assertTrue(Search.shared("file:///sdcard/Download/x.html")!!.startsWith("https://www.google.com/search?"))
        assertTrue(Search.shared("javascript:alert(1)")!!.startsWith("https://www.google.com/search?"))
        assertTrue(Search.shared("content://downloads/1")!!.startsWith("https://www.google.com/search?"))
        assertNull(Search.shared("   "))
    }

    @Test fun addressesAreSitesOfTheirOwn() {
        assertEquals("bbc.co.uk", Search.site("news.bbc.co.uk"))
        assertEquals("example.com", Search.site("a.b.example.com"))
        assertEquals("example.com", Search.site("www.example.com."))
        assertEquals("192.168.1.4", Search.site("192.168.1.4"))
        assertFalse(Search.site("192.168.1.4") == Search.site("10.0.1.4"))
        assertEquals("[::ffff:1.2.3.4]", Search.site("[::ffff:1.2.3.4]"))
    }

    @Test fun downloadRedirectsStayOnTheWebAndKeepCookiesHome() {
        val from = java.net.URL("http://example.com/files/a.zip")
        assertEquals("https://example.com/files/a.zip", Downloads.redirect(from, "https://example.com/files/a.zip").toString())
        assertEquals("http://example.com/b.zip", Downloads.redirect(from, "/b.zip").toString())
        assertNull(Downloads.redirect(from, "file:///data/data/org.tulipanlabs.lite/x"))
        assertNull(Downloads.redirect(from, "javascript:alert(1)"))
        val https = java.net.URL("https://example.com/a")
        assertTrue(Downloads.cookiesMayGo(https, from))
        assertTrue(Downloads.cookiesMayGo(java.net.URL("https://EXAMPLE.com/b"), https))
        assertFalse(Downloads.cookiesMayGo(java.net.URL("https://cdn.example.net/a"), https))
        // never from https down to plain http
        assertFalse(Downloads.cookiesMayGo(java.net.URL("http://example.com/a"), https))
    }

    @Test fun historyKeepsNoGiantEntries() {
        assertEquals("hello", Store.clip("hello", 10))
        assertEquals("hel", Store.clip("hello", 3))
        // an emoji is two chars: kept whole or not at all
        assertEquals("a", Store.clip("a\uD83D\uDE00", 2))
        assertEquals("a\uD83D\uDE00", Store.clip("a\uD83D\uDE00", 3))
    }
}
