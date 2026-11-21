package org.tulipanlabs.iris.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import org.mozilla.geckoview.AllowOrDeny
import org.mozilla.geckoview.GeckoSession.PromptDelegate
import org.tulipanlabs.iris.Prompt

/** what a page asks, as Material dialogs */
@Composable
fun PromptDialog(p: Prompt, pickFiles: (Prompt) -> Unit, done: () -> Unit) {
    fun answer(r: PromptDelegate.PromptResponse) { p.answer(r); done() }
    when (val k = p.kind) {
        is PromptDelegate.AlertPrompt -> AlertDialog(
            onDismissRequest = { answer(k.dismiss()) },
            title = k.title?.let { { Text(it) } },
            text = { Text(k.message ?: "") },
            confirmButton = { TextButton(onClick = { answer(k.dismiss()) }) { Text("OK") } },
        )
        is PromptDelegate.ButtonPrompt -> AlertDialog(
            onDismissRequest = { answer(k.confirm(PromptDelegate.ButtonPrompt.Type.NEGATIVE)) },
            title = k.title?.let { { Text(it) } },
            text = { Text(k.message ?: "") },
            confirmButton = { TextButton(onClick = { answer(k.confirm(PromptDelegate.ButtonPrompt.Type.POSITIVE)) }) { Text("OK") } },
            dismissButton = { TextButton(onClick = { answer(k.confirm(PromptDelegate.ButtonPrompt.Type.NEGATIVE)) }) { Text("Cancel") } },
        )
        is PromptDelegate.TextPrompt -> {
            var v by remember { mutableStateOf(k.defaultValue ?: "") }
            AlertDialog(
                onDismissRequest = { answer(k.dismiss()) },
                title = k.title?.let { { Text(it) } },
                text = { Column { k.message?.let { Text(it) }; OutlinedTextField(v, { v = it }, singleLine = true) } },
                confirmButton = { TextButton(onClick = { answer(k.confirm(v)) }) { Text("OK") } },
                dismissButton = { TextButton(onClick = { answer(k.dismiss()) }) { Text("Cancel") } },
            )
        }
        is PromptDelegate.AuthPrompt -> {
            var user by remember { mutableStateOf(k.authOptions.username ?: "") }
            var pass by remember { mutableStateOf("") }
            AlertDialog(
                onDismissRequest = { answer(k.dismiss()) },
                title = { Text(k.title ?: "Sign in") },
                text = {
                    Column {
                        k.message?.let { Text(it) }
                        OutlinedTextField(user, { user = it }, singleLine = true, label = { Text("User name") })
                        OutlinedTextField(pass, { pass = it }, singleLine = true, label = { Text("Password") }, visualTransformation = PasswordVisualTransformation())
                    }
                },
                confirmButton = { TextButton(onClick = { answer(k.confirm(user, pass)) }) { Text("Sign in") } },
                dismissButton = { TextButton(onClick = { answer(k.dismiss()) }) { Text("Cancel") } },
            )
        }
        is PromptDelegate.ChoicePrompt -> {
            val flat = remember { k.choices.flatMap { c -> if (c.items != null) listOf(c) + c.items!!.toList() else listOf(c) }.filter { !it.separator } }
            val multiple = k.type == PromptDelegate.ChoicePrompt.Type.MULTIPLE
            var picked by remember { mutableStateOf(flat.filter { it.selected }.map { it.id }.toSet()) }
            AlertDialog(
                onDismissRequest = { answer(k.dismiss()) },
                title = k.title?.let { { Text(it) } },
                text = {
                    LazyColumn(Modifier.heightIn(max = 420.dp)) {
                        items(flat) { c ->
                            Row(
                                Modifier.fillMaxWidth().clickable(enabled = !c.disabled && c.items == null) {
                                    if (multiple) picked = if (c.id in picked) picked - c.id else picked + c.id
                                    else answer(k.confirm(c))
                                }.padding(vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                if (multiple && c.items == null) Checkbox(c.id in picked, null)
                                Text(c.label, Modifier.padding(start = if (c.items != null) 0.dp else 8.dp))
                            }
                        }
                    }
                },
                confirmButton = {
                    if (multiple) TextButton(onClick = { answer(k.confirm(flat.filter { it.id in picked }.toTypedArray())) }) { Text("OK") }
                },
                dismissButton = { TextButton(onClick = { answer(k.dismiss()) }) { Text("Cancel") } },
            )
        }
        is PromptDelegate.FilePrompt -> LaunchedEffect(k) { pickFiles(p); done() }
        is PromptDelegate.BeforeUnloadPrompt -> AlertDialog(
            onDismissRequest = { answer(k.confirm(AllowOrDeny.DENY)) },
            title = { Text("Leave this page?") },
            text = { Text("What you changed may not be saved.") },
            confirmButton = { TextButton(onClick = { answer(k.confirm(AllowOrDeny.ALLOW)) }) { Text("Leave") } },
            dismissButton = { TextButton(onClick = { answer(k.confirm(AllowOrDeny.DENY)) }) { Text("Stay") } },
        )
        is PromptDelegate.RepostConfirmPrompt -> AlertDialog(
            onDismissRequest = { answer(k.confirm(AllowOrDeny.DENY)) },
            title = { Text("Send again?") },
            text = { Text("This page sends what you entered once more.") },
            confirmButton = { TextButton(onClick = { answer(k.confirm(AllowOrDeny.ALLOW)) }) { Text("Send") } },
            dismissButton = { TextButton(onClick = { answer(k.confirm(AllowOrDeny.DENY)) }) { Text("Cancel") } },
        )
        else -> LaunchedEffect(k) { answer(k.dismiss()) }
    }
}
