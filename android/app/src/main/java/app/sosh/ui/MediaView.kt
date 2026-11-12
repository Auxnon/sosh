package app.sosh.ui

import android.annotation.SuppressLint
import android.net.Uri
import android.view.ViewGroup
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import app.sosh.AppState
import app.sosh.data.Media
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import coil3.request.crossfade
import java.io.ByteArrayInputStream

/** A picture or a cart in a message. */
@Composable
fun MediaCard(app: AppState, m: Media) {
    if (m.isCart) CartCard(app, m) else Picture(app, m)
}

/**
 * A picture as it was shared, gifs and animated webp moving (Coil, with
 * Android's animated image decoder: see `MainActivity`). Tap for it large.
 */
@Composable
private fun Picture(app: AppState, m: Media) {
    var big by remember { mutableStateOf(false) }
    val ratio = (m.w.toFloat() / m.h.coerceAtLeast(1)).coerceIn(0.4f, 3f)
    val shape = RoundedCornerShape(16.dp)
    AsyncImage(
        ImageRequest.Builder(LocalContext.current).data(app.resolve(m.url)).crossfade(true).build(),
        m.label,
        Modifier.widthIn(max = 320.dp).heightIn(max = 360.dp).aspectRatio(ratio, matchHeightConstraintsFirst = ratio < 1f)
            .clip(shape).background(PaperDeep).border(2.dp, PaperEdge, shape).clickable { big = true },
        contentScale = ContentScale.Crop,
    )
    if (big) {
        Dialog({ big = false }, DialogProperties(usePlatformDefaultWidth = false)) {
            Box(Modifier.fillMaxSize().background(Color(0xE6120F2A)).clickable { big = false }, contentAlignment = Alignment.Center) {
                AsyncImage(app.resolve(m.url), m.label, Modifier.fillMaxWidth().padding(12.dp), contentScale = ContentScale.Fit)
            }
        }
    }
}

/**
 * A Petrichor64 cart: a cartridge to press play on, which runs it right
 * here in the chat, on its own (`CartPlayer`). One plays at a time.
 */
@Composable
private fun CartCard(app: AppState, m: Media) {
    val playing = app.playing == m.key
    Column(
        Modifier.fillMaxWidth().background(PaperDeep, RoundedCornerShape(18.dp)).border(2.dp, PaperEdge, RoundedCornerShape(18.dp)).padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Cartridge(Modifier.size(width = 34.dp, height = 40.dp))
            Column(Modifier.weight(1f)) {
                Text(m.label, color = Ink, fontWeight = FontWeight.ExtraBold, fontSize = 15.sp)
                Text("a Petrichor64 game · ${m.size / 1024} KB", color = InkDim, fontSize = 12.sp)
            }
            PlasticButton({ app.playing = if (playing) null else m.key }, tone = if (playing) Tone.Plastic else Tone.Orange) {
                Icon(if (playing) Icons.Filled.Close else Icons.Filled.PlayArrow, null, Modifier.size(18.dp))
                Text(if (playing) "Stop" else "Play", fontWeight = FontWeight.ExtraBold)
            }
        }
        if (playing) {
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                val w = if (maxWidth > 480.dp) 480.dp else maxWidth
                CartPlayer(app, m, Modifier.width(w).aspectRatio(4f / 3f).clip(RoundedCornerShape(12.dp)).border(3.dp, Edge, RoundedCornerShape(12.dp)))
            }
        }
    }
}

/** A cartridge: the plastic, a notch, its label and grip. */
@Composable
private fun Cartridge(modifier: Modifier) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        val r = CornerRadius(w * 0.12f)
        drawRoundRect(Edge, Offset(0f, h * 0.06f), Size(w, h * 0.94f), r)
        drawRoundRect(PanelHi, Offset.Zero, Size(w, h * 0.94f), r)
        drawRect(PaperDeep, Offset(w * 0.72f, 0f), Size(w * 0.28f, h * 0.14f))
        drawRoundRect(Paper, Offset(w * 0.14f, h * 0.14f), Size(w * 0.72f, h * 0.42f), CornerRadius(w * 0.06f))
        drawCircle(Accent, w * 0.1f, Offset(w * 0.32f, h * 0.32f))
        for (i in 0..3) drawRect(Edge, Offset(w * (0.2f + i * 0.17f), h * 0.66f), Size(w * 0.08f, h * 0.18f))
    }
}

/**
 * A shared cart running in a web view of its own: the server's `/play/<key>`
 * page, which fences the cart off from sosh (play_controller.ex). This view
 * adds its own fence: no session (none of the world view's user agent token,
 * no storage), nothing loaded but the engine's files and that cart from our
 * own server, and no leaving the page.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun CartPlayer(app: AppState, m: Media, modifier: Modifier = Modifier) {
    var web by remember { mutableStateOf<WebView?>(null) }
    DisposableEffect(m.key) { onDispose { web?.destroy() } }
    val base = Uri.parse(app.serverUrl)
    val allowed = setOf(
        "/play/${m.key}", "/play/worker.js", "/play.js", m.url,
        "/Petrichor64.js", "/Petrichor64_bg.wasm", "/bridge-worker.js",
        "/synth-worklet.js", "/worklet-polyfill.js", "/petrichor_synth.js", "/petrichor_synth_bg.wasm",
    )
    AndroidView(
        factory = { ctx ->
            WebView(ctx).apply {
                layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = false
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                settings.mediaPlaybackRequiresUserGesture = false
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true

                    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                        val u = request.url
                        val ours = u.scheme == base.scheme && u.host == base.host && u.port == base.port
                        if (ours && u.path in allowed) return null
                        return WebResourceResponse("text/plain", "utf-8", 403, "Forbidden", emptyMap(), ByteArrayInputStream(ByteArray(0)))
                    }
                }
                loadUrl(app.resolve("/play/${m.key}"))
                web = this
            }
        },
        modifier = modifier,
    )
}
