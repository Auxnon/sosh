package app.sosh.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.border
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import app.sosh.AppState

/**
 * The blueprints book on its own, from the menu: the game in a web view with
 * `sosh-book` in its user agent (and no `sosh-enter`, so it enters no world;
 * client/web/bridge.js puts it in book mode), the search field over it.
 * Typing filters the book's index.
 */
@Composable
fun BookScreen(app: AppState, back: () -> Unit) {
    val token = app.token ?: return
    val book = remember { BookState() }
    DisposableEffect(Unit) {
        onDispose {
            book.web?.destroy()
            book.web = null
        }
    }
    Page("Blueprints", back) {
        val frame = RoundedCornerShape(24.dp)
        Box(Modifier.fillMaxSize().padding(bottom = 10.dp).clip(frame).border(3.dp, Edge, frame)) {
            AndroidView(
                factory = { ctx ->
                    gameWebView(ctx, app.serverUrl, "sosh-token/$token sosh-book", SoshHost { }, { }).also { book.web = it }
                },
                modifier = Modifier.fillMaxSize(),
            )
            BookSearch(book, Modifier.align(Alignment.TopCenter).padding(8.dp))
        }
    }
}
