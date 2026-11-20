package app.sosh.ui

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import org.json.JSONArray
import org.json.JSONObject

/**
 * What the game's page can say to the app: `SoshHost.call(name, argsJson)`
 * (client/web/bridge.js, from the cart's own calls). Pages see it as a
 * global, so it takes only the two names the book uses and ignores the
 * rest; whatever it takes goes to the UI thread.
 */
class SoshHost(private val onBook: (Boolean) -> Unit) {
    private val ui = Handler(Looper.getMainLooper())

    @JavascriptInterface
    fun call(name: String, argsJson: String) {
        if (name != "book") return // book_step and anything else: not ours (yet)
        val first = try { JSONArray(argsJson).optString(0) } catch (e: Exception) { return }
        when (first) {
            "open" -> ui.post { onBook(true) }
            "closed" -> ui.post { onBook(false) }
        }
    }
}

/**
 * A web view of the server's own game page, the setup the world and the
 * book screen share: scripts and storage on, our marks in the user agent
 * (`sosh-token/<t>` and `sosh-enter/<id>` or `sosh-book`), the page loaded
 * from [base]. It never leaves that server: a link or redirect to anywhere
 * else is dropped (and an `http` page can't be sent to a `file:` or
 * `intent:` URL), since pages in it can reach `SoshHost`.
 */
@SuppressLint("SetJavaScriptEnabled")
fun gameWebView(ctx: Context, base: String, marks: String, host: SoshHost?, onLoaded: () -> Unit): WebView =
    WebView(ctx).apply {
        layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.mediaPlaybackRequiresUserGesture = false
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        settings.userAgentString = settings.userAgentString + " " + marks
        val origin = base.toUri()
        fun ours(u: android.net.Uri) =
            u.scheme == origin.scheme && u.host == origin.host && u.port == origin.port
        webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String?) = onLoaded()
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = !ours(request.url)
        }
        webChromeClient = WebChromeClient()
        if (host != null) addJavascriptInterface(host, "SoshHost")
        loadUrl("$base/")
    }

/** Call a global function of the game by name; the arguments go through a JSON encoder. */
fun WebView.soshCall(name: String, vararg args: Any) {
    val list = args.joinToString(",") { if (it is String) JSONObject.quote(it) else it.toString() }
    evaluateJavascript("window.soshCall&&window.soshCall(${JSONObject.quote(name)}${if (list.isEmpty()) "" else ",$list"})", null)
}

/** The crafting book as the world has it: whether the game has it open, and the web view to ask. */
class BookState {
    var open by mutableStateOf(false)
    var web: WebView? = null
    var query by mutableStateOf("")

    fun search(text: String) {
        query = text
        web?.soshCall("book_search", text)
    }

    fun close() = web?.soshCall("book_close")
}

/** The book's search field: typing filters the recipe index in the game. [onClose] adds an x. */
@Composable
fun BookSearch(book: BookState, modifier: Modifier = Modifier, onClose: (() -> Unit)? = null) {
    Row(
        modifier.fillMaxWidth().paper(RoundedCornerShape(20.dp)).padding(8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        OutlinedTextField(
            book.query, { book.search(it.take(64)) }, Modifier.weight(1f),
            singleLine = true, shape = RoundedCornerShape(16.dp),
            placeholder = { Text("Search what can be made") },
            leadingIcon = { Icon(Icons.Filled.Search, null, Modifier.size(20.dp)) },
            colors = OutlinedTextFieldDefaults.colors(
                focusedTextColor = Ink, unfocusedTextColor = Ink, cursorColor = Ink,
                focusedContainerColor = Color(0xFFFFFBEE), unfocusedContainerColor = Color(0xFFFFFBEE),
            ),
        )
        if (onClose != null) PlasticButton(onClose, Modifier.size(44.dp), tone = Tone.Green, shape = RoundedCornerShape(14.dp)) {
            Icon(Icons.Filled.Close, "close the book")
        }
    }
}
