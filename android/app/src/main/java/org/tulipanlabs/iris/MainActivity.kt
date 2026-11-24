package org.tulipanlabs.iris

import android.Manifest
import android.app.SearchManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import org.tulipanlabs.iris.ui.BrowserScreen
import org.tulipanlabs.iris.ui.IrisTheme
import org.tulipanlabs.iris.ui.Look

class MainActivity : ComponentActivity() {
    private val model: BrowserModel by viewModels()

    // a page's file field: Android's picker, answered back to the page
    private val pick = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        val req = model.fileRequest ?: return@registerForActivityResult
        model.fileRequest = null
        req.answer(req.parseResult(r.resultCode, r.data))
    }

    // calls: Android asks for the camera and the microphone once
    private val media = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { answer() }

    // background audio: the notification permission, asked the first time
    // audio plays (never at launch); the answer changes nothing about the
    // sound — the service runs and the media notification shows either way
    private val notify = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    /** gives the page what Android allows Iris */
    private fun answer() {
        val req = model.mediaRequest ?: return
        model.mediaRequest = null
        val granted = req.resources.filter {
            when (it) {
                PagePermission.CAMERA -> has(Manifest.permission.CAMERA)
                PagePermission.MICROPHONE -> has(Manifest.permission.RECORD_AUDIO)
                PagePermission.PROTECTED_MEDIA -> true
            }
        }
        if (granted.isEmpty()) req.deny() else req.grant(granted)
    }

    private fun has(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // the look before the first page is made, so it opens in its colours
        val night = (resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK) == android.content.res.Configuration.UI_MODE_NIGHT_YES
        model.dark = Look.isDark(night)
        model.attached(this)
        setContent {
            val system = isSystemInDarkTheme()
            val dark = Look.isDark(system)
            LaunchedEffect(dark) { model.dark = dark }
            IrisTheme(dark) {
                BrowserScreen(model)
                LaunchedEffect(model.mediaRequest) {
                    val req = model.mediaRequest ?: return@LaunchedEffect
                    val need = buildList {
                        if (PagePermission.CAMERA in req.resources && !has(Manifest.permission.CAMERA)) add(Manifest.permission.CAMERA)
                        if (PagePermission.MICROPHONE in req.resources && !has(Manifest.permission.RECORD_AUDIO)) add(Manifest.permission.RECORD_AUDIO)
                    }
                    if (need.isEmpty()) answer() else media.launch(need.toTypedArray())
                }
                LaunchedEffect(model.fileRequest) {
                    val req = model.fileRequest ?: return@LaunchedEffect
                    val i = runCatching { req.createIntent() }.getOrNull()
                    if (i == null) { req.answer(null); model.fileRequest = null } else pick.launch(i)
                }
                LaunchedEffect(model.notificationRequest) {
                    if (model.notificationRequest) {
                        model.notificationRequest = false
                        notify.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                }
                // back: leave full screen, then go back in the page; at the
                // start of a tab's history Iris goes to the background, its
                // tabs kept
                BackHandler {
                    val t = model.current
                    when {
                        model.fullscreen -> model.exitFullscreen()
                        t?.canBack == true -> t.back()
                        else -> moveTaskToBack(true)
                    }
                }
            }
        }
        if (savedInstanceState == null) handle(intent)
        lifecycleScope.launch { Updater.check() }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(i: Intent?) {
        when (i?.action) {
            // another app's link opens only when it is a web address: an
            // explicit intent could carry javascript:, file: or intent: too
            Intent.ACTION_VIEW -> i.dataString?.let(Search::external)?.let { model.newTab(it) }
            Intent.ACTION_WEB_SEARCH -> i.getStringExtra(SearchManager.QUERY)?.let { model.newTab(Search.aiUrl(it)) }
            Intent.ACTION_SEND -> i.getStringExtra(Intent.EXTRA_TEXT)?.let { model.newTab(Search.resolve(it)) }
        }
    }

    override fun onPause() {
        super.onPause()
        // the page that plays is not paused, and the service that keeps it
        // playing starts here, while Iris is still in front; every other
        // shown page pauses as it always has
        model.enterBackground()
        model.save()
    }

    override fun onResume() {
        super.onResume()
        model.leaveBackground()
        model.current?.web?.onResume()
    }

    override fun onDestroy() {
        if (model.activity === this) model.activity = null
        super.onDestroy()
    }
}
