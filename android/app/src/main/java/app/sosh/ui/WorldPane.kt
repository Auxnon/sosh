package app.sosh.ui

import android.annotation.SuppressLint
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.ViewGroup
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import app.sosh.AppState

/**
 * A server's world: the same web game the browser gets, in a web view. Its
 * socket signs in by user agent (`sosh-token/<token>`), the game opens this
 * server straight away (`sosh-enter/<id>`), and, knowing it's in the app,
 * leaves chat, looks and the way home to the app's own screens. Tapping the
 * world walks there and dragging it turns the camera; a controller works
 * too (`Gamepad`).
 *
 * It stays loaded while it's slid away (`shown` false), only paused, so
 * sliding it back is instant.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun WorldPane(app: AppState, serverId: Long, shown: Boolean, modifier: Modifier = Modifier) {
    val token = app.token ?: return
    var web by remember { mutableStateOf<WebView?>(null) }

    LaunchedEffect(web, shown) {
        val w = web ?: return@LaunchedEffect
        if (shown) {
            w.onResume()
            Gamepad.web = w
        } else {
            w.onPause()
            if (Gamepad.web == w) Gamepad.web = null
        }
    }
    DisposableEffect(Unit) {
        onDispose {
            web?.let { w ->
                if (Gamepad.web == w) Gamepad.web = null
                w.destroy()
            }
        }
    }

    AndroidView(
        factory = { ctx ->
            WebView(ctx).apply {
                layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.mediaPlaybackRequiresUserGesture = false
                settings.userAgentString = settings.userAgentString + " sosh-token/$token sosh-enter/$serverId"
                webViewClient = WebViewClient()
                webChromeClient = WebChromeClient()
                loadUrl(app.serverUrl + "/")
                web = this
            }
        },
        modifier = modifier,
    )
}

/**
 * A controller, pressing the game's keys in the world that's showing. The
 * web view can't be trusted to hand controllers to the page, so the
 * activity passes their events here (`MainActivity`). The same mapping as
 * the browser's (`client/web/gamepad.js`):
 *
 *   left stick / d-pad   walk (w a s d)        A   take the helm / let go (b)
 *   right stick, L1/R1   turn the camera (q e)  B   close the bag (escape)
 *   R2 / L2              climb / sink at a helm X   pose, put down (g)
 *   select               ask a helper (h)       Y   bag (i)
 */
object Gamepad {
    var web: WebView? = null
        set(v) {
            if (v != field) release()
            field = v
        }

    private const val DEAD = 0.4f
    private val CODES = mapOf(
        "w" to "KeyW", "a" to "KeyA", "s" to "KeyS", "d" to "KeyD", "q" to "KeyQ", "e" to "KeyE",
        "b" to "KeyB", "Escape" to "Escape", "g" to "KeyG", "i" to "KeyI", "c" to "KeyC", " " to "Space", "h" to "KeyH",
    )
    private val BUTTONS = mapOf(
        KeyEvent.KEYCODE_BUTTON_A to "b",
        KeyEvent.KEYCODE_BUTTON_B to "Escape",
        KeyEvent.KEYCODE_BUTTON_X to "g",
        KeyEvent.KEYCODE_BUTTON_Y to "i",
        KeyEvent.KEYCODE_BUTTON_L1 to "q",
        KeyEvent.KEYCODE_BUTTON_R1 to "e",
        KeyEvent.KEYCODE_BUTTON_L2 to "c",
        KeyEvent.KEYCODE_BUTTON_R2 to " ",
        KeyEvent.KEYCODE_BUTTON_SELECT to "h",
        KeyEvent.KEYCODE_DPAD_UP to "w",
        KeyEvent.KEYCODE_DPAD_DOWN to "s",
        KeyEvent.KEYCODE_DPAD_LEFT to "a",
        KeyEvent.KEYCODE_DPAD_RIGHT to "d",
    )

    // what the buttons and the sticks each hold down; the game sees both
    private val buttons = mutableSetOf<String>()
    private var axes = setOf<String>()
    private val held = mutableSetOf<String>()

    private fun fromController(source: Int) =
        source and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD ||
            source and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK

    /** A controller's button; true if the game took it. */
    fun key(e: KeyEvent): Boolean {
        if (web == null) return false
        val source = e.device?.sources ?: e.source
        if (!fromController(source)) return false
        val k = BUTTONS[e.keyCode] ?: return false
        when (e.action) {
            KeyEvent.ACTION_DOWN -> if (e.repeatCount == 0) buttons.add(k)
            KeyEvent.ACTION_UP -> buttons.remove(k)
        }
        sync()
        return true
    }

    /** A controller's sticks, d-pad hat and triggers; true if the game took it. */
    fun motion(e: MotionEvent): Boolean {
        if (web == null || !fromController(e.source) || e.action != MotionEvent.ACTION_MOVE) return false
        val want = mutableSetOf<String>()
        val x = e.getAxisValue(MotionEvent.AXIS_X) + e.getAxisValue(MotionEvent.AXIS_HAT_X)
        val y = e.getAxisValue(MotionEvent.AXIS_Y) + e.getAxisValue(MotionEvent.AXIS_HAT_Y)
        val rx = e.getAxisValue(MotionEvent.AXIS_Z)
        if (y < -DEAD) want.add("w")
        if (y > DEAD) want.add("s")
        if (x < -DEAD) want.add("a")
        if (x > DEAD) want.add("d")
        if (rx < -DEAD) want.add("q")
        if (rx > DEAD) want.add("e")
        if (maxOf(e.getAxisValue(MotionEvent.AXIS_RTRIGGER), e.getAxisValue(MotionEvent.AXIS_GAS)) > 0.5f) want.add(" ")
        if (maxOf(e.getAxisValue(MotionEvent.AXIS_LTRIGGER), e.getAxisValue(MotionEvent.AXIS_BRAKE)) > 0.5f) want.add("c")
        axes = want
        sync()
        return true
    }

    private fun sync() {
        val want = buttons + axes
        for (k in held.toList()) if (k !in want) { held.remove(k); press(k, false) }
        for (k in want) if (k !in held) { held.add(k); press(k, true) }
    }

    /** Let go of everything, so nothing stays held in a world we've left. */
    private fun release() {
        buttons.clear()
        axes = emptySet()
        sync()
    }

    private fun press(k: String, down: Boolean) {
        val type = if (down) "keydown" else "keyup"
        web?.evaluateJavascript(
            "(function(){var t=document.querySelector('canvas')||document.body;" +
                "t.dispatchEvent(new KeyboardEvent('$type',{key:'$k',code:'${CODES[k]}',bubbles:true}));})()",
            null,
        )
    }
}
