package org.tulipanlabs.iris

import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoSession.PromptDelegate
import org.mozilla.geckoview.GeckoSession.PromptDelegate.PromptResponse

/** a question a page asks: an alert, a confirm, some text, a choice, a file */
class Prompt(val kind: PromptDelegate.BasePrompt, val result: GeckoResult<PromptResponse>) {
    fun answer(r: PromptResponse) {
        result.complete(r)
    }
}

object Prompts {
    fun delegate(model: BrowserModel) = object : PromptDelegate {
        private fun ask(p: PromptDelegate.BasePrompt): GeckoResult<PromptResponse> {
            val r = GeckoResult<PromptResponse>()
            model.prompt = Prompt(p, r)
            return r
        }

        override fun onAlertPrompt(session: GeckoSession, prompt: PromptDelegate.AlertPrompt) = ask(prompt)
        override fun onButtonPrompt(session: GeckoSession, prompt: PromptDelegate.ButtonPrompt) = ask(prompt)
        override fun onTextPrompt(session: GeckoSession, prompt: PromptDelegate.TextPrompt) = ask(prompt)
        override fun onChoicePrompt(session: GeckoSession, prompt: PromptDelegate.ChoicePrompt) = ask(prompt)
        override fun onFilePrompt(session: GeckoSession, prompt: PromptDelegate.FilePrompt) = ask(prompt)
        override fun onAuthPrompt(session: GeckoSession, prompt: PromptDelegate.AuthPrompt) = ask(prompt)
        override fun onBeforeUnloadPrompt(session: GeckoSession, prompt: PromptDelegate.BeforeUnloadPrompt) = ask(prompt)
        override fun onRepostConfirmPrompt(session: GeckoSession, prompt: PromptDelegate.RepostConfirmPrompt) = ask(prompt)
        // pop-ups are decided in onLoadRequest; the engine's own pop-up
        // prompt (for windows opened without a tap) is always a no
        override fun onPopupPrompt(session: GeckoSession, prompt: PromptDelegate.PopupPrompt): GeckoResult<PromptResponse> =
            GeckoResult.fromValue(prompt.confirm(org.mozilla.geckoview.AllowOrDeny.DENY))
    }
}
