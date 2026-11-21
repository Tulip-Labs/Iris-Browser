package org.tulipanlabs.iris

import android.app.SearchManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        model.attached(this)
        setContent {
            val system = isSystemInDarkTheme()
            val dark = Look.isDark(system)
            LaunchedEffect(dark) { model.dark = dark }
            IrisTheme(dark) {
                BrowserScreen(model)
                // back: leave full screen, then go back in the page; at the
                // start of a tab's history Iris goes to the background, its
                // tabs kept
                BackHandler {
                    val t = model.current
                    when {
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
            Intent.ACTION_VIEW -> i.dataString?.let { model.newTab(it) }
            Intent.ACTION_WEB_SEARCH -> i.getStringExtra(SearchManager.QUERY)?.let { model.newTab(Search.aiUrl(it)) }
            Intent.ACTION_SEND -> i.getStringExtra(Intent.EXTRA_TEXT)?.let { model.newTab(Search.resolve(it)) }
        }
    }

    override fun onPause() {
        super.onPause()
        model.current?.web?.onPause()
        model.save()
    }

    override fun onResume() {
        super.onResume()
        model.current?.web?.onResume()
    }

    override fun onDestroy() {
        if (model.activity === this) model.activity = null
        super.onDestroy()
    }
}
