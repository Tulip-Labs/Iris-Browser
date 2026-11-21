package org.tulipanlabs.iris

import android.app.SearchManager
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import org.mozilla.geckoview.GeckoSession.PromptDelegate
import org.tulipanlabs.iris.ui.BrowserScreen
import org.tulipanlabs.iris.ui.IrisTheme

class MainActivity : ComponentActivity() {
    private val model: BrowserModel by viewModels()
    private var filePrompt: Prompt? = null

    // a page's file field: Android's picker, answered back to the page
    private val pickOne = registerForActivityResult(ActivityResultContracts.GetContent()) { uri -> answerFiles(listOfNotNull(uri)) }
    private val pickMany = registerForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris -> answerFiles(uris) }

    private fun answerFiles(uris: List<Uri>) {
        val p = filePrompt ?: return
        filePrompt = null
        val k = p.kind as PromptDelegate.FilePrompt
        p.answer(
            when {
                uris.isEmpty() -> k.dismiss()
                k.type == PromptDelegate.FilePrompt.Type.MULTIPLE -> k.confirm(this, uris.toTypedArray())
                else -> k.confirm(this, uris[0])
            },
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            IrisTheme {
                BrowserScreen(model) { p ->
                    filePrompt = p
                    val k = p.kind as PromptDelegate.FilePrompt
                    val mime = k.mimeTypes?.firstOrNull()?.takeIf { it.contains('/') } ?: "*/*"
                    if (k.type == PromptDelegate.FilePrompt.Type.MULTIPLE) pickMany.launch(mime) else pickOne.launch(mime)
                }
                // back: leave full screen, then go back in the page; at the
                // start of a tab's history Iris goes to the background, its
                // tabs kept
                BackHandler {
                    val t = model.current
                    when {
                        model.fullscreen -> t?.session?.exitFullScreen()
                        t?.canBack == true -> t.session?.goBack()
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
        model.save()
    }
}
