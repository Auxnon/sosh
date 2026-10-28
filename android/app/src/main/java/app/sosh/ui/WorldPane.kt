package app.sosh.ui

import android.annotation.SuppressLint
import android.app.Activity
import android.content.pm.ActivityInfo
import android.view.ViewGroup
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import app.sosh.AppState

/**
 * A server's world: the same web game the browser gets, in a web view. Its
 * socket signs in by user agent (`sosh-token/<token>`) and the game opens
 * this server straight away (`sosh-enter/<id>`), so there's no second
 * sign-in. Over it, native controls: the chat bar uses the phone's
 * keyboard and posts to the server's chat (which the game shows, as a
 * bubble over us too), and the pad and buttons press the game's keys.
 * Tapping the world walks there, as a click does.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun WorldScreen(app: AppState, back: () -> Unit) {
    val server = serverFor(app) ?: run { back(); return }
    val token = app.token ?: run { back(); return }
    var web by remember { mutableStateOf<WebView?>(null) }
    var chatting by remember { mutableStateOf(false) }
    var text by remember { mutableStateOf("") }

    // the game is drawn for a landscape screen: turn the phone while it's open
    val activity = LocalContext.current as? Activity
    DisposableEffect(Unit) {
        val was = activity?.requestedOrientation
        activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        onDispose {
            web?.destroy()
            if (was != null) activity.requestedOrientation = was
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            factory = { ctx ->
                WebView(ctx).apply {
                    layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.mediaPlaybackRequiresUserGesture = false
                    settings.userAgentString = settings.userAgentString + " sosh-token/$token sosh-enter/${server.id}"
                    webViewClient = WebViewClient()
                    webChromeClient = WebChromeClient()
                    loadUrl(app.serverUrl + "/")
                    web = this
                }
            },
            modifier = Modifier.fillMaxSize(),
        )

        Row(Modifier.systemBarsPadding().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(back, Modifier.background(Panel.copy(alpha = 0.8f), CircleShape)) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "back")
            }
            Spacer(Modifier.size(8.dp))
            Text(server.name, color = TextMain, modifier = Modifier.background(Panel.copy(alpha = 0.7f), RoundedCornerShape(8.dp)).padding(8.dp))
        }

        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().imePadding().systemBarsPadding().padding(8.dp),
        ) {
            if (!chatting) {
                Row(verticalAlignment = Alignment.Bottom) {
                    Pad(web)
                    Spacer(Modifier.weight(1f))
                    Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            KeyButton(web, "⟲", "q", "KeyQ")
                            KeyButton(web, "⟳", "e", "KeyE")
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            KeyButton(web, "helm", "b", "KeyB")
                            KeyButton(web, "pose", "g", "KeyG")
                            KeyButton(web, "bag", "i", "KeyI")
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            KeyButton(web, "wave", "7", "Digit7")
                            KeyButton(web, "dance", "8", "Digit8")
                            IconButton({ chatting = true }, Modifier.background(Accent, CircleShape)) {
                                Icon(Icons.Filled.ChatBubble, "chat", tint = Night)
                            }
                        }
                    }
                }
            } else {
                Row(Modifier.fillMaxWidth().background(Panel, RoundedCornerShape(24.dp)).padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
                    TextField(
                        text, { text = it.take(280) }, Modifier.weight(1f),
                        placeholder = { Text("Say something") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Send),
                        keyboardActions = KeyboardActions(onSend = {
                            if (text.isNotBlank()) app.post(text.trim())
                            text = ""
                            chatting = false
                        }),
                        colors = TextFieldDefaults.colors(focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent),
                    )
                    IconButton({
                        if (text.isNotBlank()) app.post(text.trim())
                        text = ""
                        chatting = false
                    }) { Icon(Icons.AutoMirrored.Filled.Send, "send", tint = Accent) }
                }
            }
        }
    }
}

/** Press or release a key in the game (its canvas listens for them). */
private fun key(web: WebView?, key: String, code: String, down: Boolean) {
    val type = if (down) "keydown" else "keyup"
    web?.evaluateJavascript(
        "(function(){var t=document.querySelector('canvas')||document.body;" +
            "t.dispatchEvent(new KeyboardEvent('$type',{key:'$key',code:'$code',bubbles:true}));})()",
        null,
    )
}

/** Held down for as long as it's touched. */
private fun Modifier.holdKey(web: WebView?, k: String, code: String) = pointerInput(web) {
    awaitEachGesture {
        awaitFirstDown()
        key(web, k, code, true)
        waitForUpOrCancellation()
        key(web, k, code, false)
    }
}

@Composable
private fun Pad(web: WebView?) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        PadKey(web, "▲", "w", "KeyW")
        Row {
            PadKey(web, "◀", "a", "KeyA")
            Spacer(Modifier.size(48.dp))
            PadKey(web, "▶", "d", "KeyD")
        }
        PadKey(web, "▼", "s", "KeyS")
    }
}

@Composable
private fun PadKey(web: WebView?, label: String, k: String, code: String) {
    Box(
        Modifier.size(48.dp).background(Panel.copy(alpha = 0.75f), RoundedCornerShape(10.dp)).holdKey(web, k, code),
        contentAlignment = Alignment.Center,
    ) { Text(label, color = TextMain) }
}

@Composable
private fun KeyButton(web: WebView?, label: String, k: String, code: String) {
    Surface(
        color = Panel.copy(alpha = 0.8f),
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.holdKey(web, k, code),
    ) { Text(label, color = TextMain, modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) }
}
