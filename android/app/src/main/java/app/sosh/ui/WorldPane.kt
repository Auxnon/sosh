package app.sosh.ui

import android.annotation.SuppressLint
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.webkit.WebView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import app.sosh.AppState
import kotlinx.coroutines.delay
import org.json.JSONObject

/**
 * A server's world: the same web game the browser gets, in a web view. Its
 * socket signs in by user agent (`sosh-token/<token>`), the game opens this
 * server straight away (`sosh-enter/<id>`), and, knowing it's in the app,
 * leaves chat, looks and the way home to the app's own screens. Tapping the
 * world walks there and dragging it turns the camera; a controller and a
 * keyboard work too (`Gamepad`).
 *
 * Its page tells the app when the crafting book opens or closes (`SoshHost`,
 * client/web/bridge.js): `book` says so, and the search field sits over it.
 *
 * It stays loaded while it's slid away (`shown` false), only paused, so
 * sliding it back is instant.
 *
 * Its touches are its own: the drawer around it never takes a drag that
 * starts on the world. And the engine is nudged to read its size again once
 * the pane settles and while it's starting: it boots at a 640x548 stand-in,
 * and a size that came while it was being built (the pane sliding open)
 * can be missed, leaving a tall phone with a squashed wide picture.
 *
 * Until the game says it's in the world (`screen=world` from
 * client/scripts/web.lua, read off `<html data-sosh-screen>`), a spinner
 * covers it. A screen that wants us (signing in, making a character) lifts
 * it too, and so does a while gone by, for a server whose game doesn't say.
 */
@SuppressLint("SetJavaScriptEnabled", "ClickableViewAccessibility")
@Composable
fun WorldPane(app: AppState, serverId: Long, shown: Boolean, book: BookState, modifier: Modifier = Modifier) {
    val token = app.token ?: return
    var web by remember { mutableStateOf<WebView?>(null) }
    var size by remember { mutableStateOf(IntSize.Zero) }
    var loaded by remember { mutableStateOf(0) }
    var ready by remember { mutableStateOf(false) }

    LaunchedEffect(web, loaded) {
        val w = web ?: return@LaunchedEffect
        var waited = 0L
        while (!ready) {
            delay(400)
            if (loaded > 0) waited += 400
            w.evaluateJavascript("document.documentElement.dataset.soshScreen||''") { r ->
                val screen = r?.trim('"') ?: ""
                if (screen == "world" || screen == "auth" || screen == "creator") ready = true
            }
            if (waited > 25_000) ready = true
        }
    }

    LaunchedEffect(web, shown) {
        val w = web ?: return@LaunchedEffect
        if (shown) {
            w.onResume()
            Gamepad.web = w
            Gamepad.book = { book.open }
        } else {
            w.onPause()
            if (Gamepad.web == w) Gamepad.web = null
        }
    }
    // once the size stops changing (the slide is over), and a few times
    // while the engine starts after the page loads
    LaunchedEffect(web, size, loaded, shown) {
        val w = web ?: return@LaunchedEffect
        if (!shown || size.width == 0 || size.height == 0) return@LaunchedEffect
        delay(400)
        nudge(w)
        if (loaded > 0) for (wait in listOf(1500L, 3000L, 5000L)) {
            delay(wait)
            nudge(w)
        }
    }
    DisposableEffect(Unit) {
        onDispose {
            web?.let { w ->
                if (book.web == w) { book.web = null; book.open = false }
                if (Gamepad.web == w) Gamepad.web = null
                w.destroy()
            }
        }
    }

    // around the web view, so it has each touch before they're marked used
    Box(modifier.keepsTouches()) {
    AndroidView(
        factory = { ctx ->
            gameWebView(ctx, app.serverUrl, "sosh-token/$token sosh-enter/$serverId", SoshHost { book.open = it }, { loaded++ }).apply {
                // a drag on the world is the world's (turning the camera):
                // this holds off Android views around us; keepsTouches holds
                // off Compose's own gestures (the drawer's swipe)
                setOnTouchListener { v, e ->
                    if (e.actionMasked == MotionEvent.ACTION_DOWN) v.parent?.requestDisallowInterceptTouchEvent(true)
                    false
                }
                web = this
                book.web = this
            }
        },
        modifier = Modifier.fillMaxSize().onSizeChanged { size = it },
    )
    if (!ready) {
        Column(
            Modifier.fillMaxSize().background(Night),
            verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            CircularProgressIndicator(Modifier.size(44.dp), color = Accent, trackColor = Panel, strokeWidth = 5.dp)
            Text("Into the world…", color = TextDim, fontWeight = FontWeight.Bold, fontSize = 14.sp)
        }
    }
    }
}

/**
 * Make the engine read its size again: its canvas one pixel shorter for a
 * frame, so the canvas's resize observer (winit's) reports the real size.
 */
private fun nudge(w: WebView) {
    w.evaluateJavascript(
        "(function(){var c=document.querySelector('canvas');if(!c)return;" +
            "c.style.height='calc(100% - 1px)';" +
            "requestAnimationFrame(function(){requestAnimationFrame(function(){c.style.height='100%';});});})()",
        null,
    )
}

/**
 * A controller or a keyboard plugged into the phone, pressing the game's
 * keys in the world that's showing. The web view can't be trusted to hand
 * either to the page (it needs the focus, and the canvas in it the page's),
 * so the activity passes their events here first (`MainActivity`) and they
 * go to the engine's canvas as the browser's own key events would.
 *
 * A keyboard's keys go as themselves (the game's keys are in
 * client/scripts/tools.lua), unless something of the app's is being typed
 * into. A controller, laid out like an Xbox one, the same as the browser's
 * (`client/web/gamepad.js`):
 *
 *   left stick / d-pad   walk, steer (arrows)   A      take the helm / let go (b)
 *   right stick, LB/RB   turn the camera (q e)  B      close what's open (escape)
 *   RT / LT              climb / sink at a helm X      pose, put down (g)
 *   view (back)          ask a helper (h)       Y      bag (i)
 *   menu (start)         the book (o)           L3/R3  what the tool uses (z x)
 *
 * While the book is open its keys type into its search, so a controller
 * only turns its pages (left, right) and shuts it (B, menu).
 */
object Gamepad {
    var web: WebView? = null
        set(v) {
            if (v != field) release()
            field = v
        }

    /** Whether the world's book is open (its keys are a search field's then). */
    var book: () -> Boolean = { false }

    private const val DEAD = 0.4f
    private val CODES = mapOf(
        "ArrowUp" to "ArrowUp", "ArrowDown" to "ArrowDown", "ArrowLeft" to "ArrowLeft", "ArrowRight" to "ArrowRight",
        "q" to "KeyQ", "e" to "KeyE", "b" to "KeyB", "Escape" to "Escape", "g" to "KeyG", "i" to "KeyI",
        "c" to "KeyC", " " to "Space", "h" to "KeyH", "o" to "KeyO", "z" to "KeyZ", "x" to "KeyX",
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
        KeyEvent.KEYCODE_BUTTON_START to "o",
        KeyEvent.KEYCODE_BUTTON_THUMBL to "z",
        KeyEvent.KEYCODE_BUTTON_THUMBR to "x",
        KeyEvent.KEYCODE_DPAD_UP to "ArrowUp",
        KeyEvent.KEYCODE_DPAD_DOWN to "ArrowDown",
        KeyEvent.KEYCODE_DPAD_LEFT to "ArrowLeft",
        KeyEvent.KEYCODE_DPAD_RIGHT to "ArrowRight",
    )
    // all a controller may press while the book is open
    private val IN_BOOK = setOf("ArrowLeft", "ArrowRight", "Escape")

    // a keyboard's keys that aren't a character: Android's code to the page's `key` and `code`
    private val NAMED = mapOf(
        KeyEvent.KEYCODE_DPAD_UP to ("ArrowUp" to "ArrowUp"),
        KeyEvent.KEYCODE_DPAD_DOWN to ("ArrowDown" to "ArrowDown"),
        KeyEvent.KEYCODE_DPAD_LEFT to ("ArrowLeft" to "ArrowLeft"),
        KeyEvent.KEYCODE_DPAD_RIGHT to ("ArrowRight" to "ArrowRight"),
        KeyEvent.KEYCODE_ENTER to ("Enter" to "Enter"),
        KeyEvent.KEYCODE_NUMPAD_ENTER to ("Enter" to "NumpadEnter"),
        KeyEvent.KEYCODE_ESCAPE to ("Escape" to "Escape"),
        KeyEvent.KEYCODE_TAB to ("Tab" to "Tab"),
        KeyEvent.KEYCODE_DEL to ("Backspace" to "Backspace"),
        KeyEvent.KEYCODE_FORWARD_DEL to ("Delete" to "Delete"),
        KeyEvent.KEYCODE_SHIFT_LEFT to ("Shift" to "ShiftLeft"),
        KeyEvent.KEYCODE_SHIFT_RIGHT to ("Shift" to "ShiftRight"),
        KeyEvent.KEYCODE_SPACE to (" " to "Space"),
    )
    // and the ones that are, by where they sit on the board
    private val PUNCTUATION = mapOf(
        KeyEvent.KEYCODE_COMMA to "Comma", KeyEvent.KEYCODE_PERIOD to "Period", KeyEvent.KEYCODE_SLASH to "Slash",
        KeyEvent.KEYCODE_SEMICOLON to "Semicolon", KeyEvent.KEYCODE_APOSTROPHE to "Quote",
        KeyEvent.KEYCODE_LEFT_BRACKET to "BracketLeft", KeyEvent.KEYCODE_RIGHT_BRACKET to "BracketRight",
        KeyEvent.KEYCODE_BACKSLASH to "Backslash", KeyEvent.KEYCODE_MINUS to "Minus",
        KeyEvent.KEYCODE_EQUALS to "Equal", KeyEvent.KEYCODE_GRAVE to "Backquote",
    )

    // what the buttons and the sticks each hold down; the game sees both
    private val buttons = mutableSetOf<String>()
    private var axes = setOf<String>()
    private val held = mutableSetOf<String>()
    // a keyboard's keys that are down, by the page's `code`, with the `key` each went down as
    private val typed = mutableMapOf<String, String>()

    private fun fromController(source: Int) =
        source and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD ||
            source and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK

    /**
     * A controller's button or a keyboard's key; true if the game took it.
     * [typing] says whether the app has a text field of its own being typed
     * into, which keeps the keyboard.
     */
    fun key(e: KeyEvent, typing: () -> Boolean): Boolean {
        if (web == null) return false
        val source = e.device?.sources ?: e.source
        if (!fromController(source)) return keyboard(e, typing)
        val k = BUTTONS[e.keyCode] ?: return false
        when (e.action) {
            KeyEvent.ACTION_DOWN -> if (e.repeatCount == 0) buttons.add(k)
            KeyEvent.ACTION_UP -> buttons.remove(k)
        }
        sync()
        return true
    }

    /** The page's `key` and `code` for a keyboard's key, if it's one the game could want. */
    private fun named(e: KeyEvent): Pair<String, String>? {
        NAMED[e.keyCode]?.let { return it }
        val code = when (e.keyCode) {
            in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z -> "Key" + ('A' + (e.keyCode - KeyEvent.KEYCODE_A))
            in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 -> "Digit" + (e.keyCode - KeyEvent.KEYCODE_0)
            in KeyEvent.KEYCODE_NUMPAD_0..KeyEvent.KEYCODE_NUMPAD_9 -> "Numpad" + (e.keyCode - KeyEvent.KEYCODE_NUMPAD_0)
            else -> PUNCTUATION[e.keyCode] ?: return null
        }
        val char = e.unicodeChar
        if (char == 0 || char and KeyCharacterMap.COMBINING_ACCENT != 0) return null
        return String(Character.toChars(char)) to code
    }

    /** A keyboard's key, to the game as itself. System keys and shortcuts stay the system's. */
    private fun keyboard(e: KeyEvent, typing: () -> Boolean): Boolean {
        if (e.isCtrlPressed || e.isAltPressed || e.isMetaPressed) return false
        val (key, code) = named(e) ?: return false
        when (e.action) {
            KeyEvent.ACTION_DOWN -> {
                // a key already down is ours to the end; a new one isn't while the app is typed into
                if (code !in typed && typing()) return false
                typed[code] = key
                press(key, code, true, e.repeatCount > 0)
            }
            KeyEvent.ACTION_UP -> {
                // let go as what went down (shift may have changed since)
                val was = typed.remove(code) ?: return false
                press(was, code, false)
            }
            else -> return false
        }
        return true
    }

    /** A controller's sticks, d-pad hat and triggers; true if the game took it. */
    fun motion(e: MotionEvent): Boolean {
        if (web == null || !fromController(e.source) || e.action != MotionEvent.ACTION_MOVE) return false
        val want = mutableSetOf<String>()
        val x = e.getAxisValue(MotionEvent.AXIS_X) + e.getAxisValue(MotionEvent.AXIS_HAT_X)
        val y = e.getAxisValue(MotionEvent.AXIS_Y) + e.getAxisValue(MotionEvent.AXIS_HAT_Y)
        val rx = e.getAxisValue(MotionEvent.AXIS_Z)
        if (y < -DEAD) want.add("ArrowUp")
        if (y > DEAD) want.add("ArrowDown")
        if (x < -DEAD) want.add("ArrowLeft")
        if (x > DEAD) want.add("ArrowRight")
        if (rx < -DEAD) want.add("q")
        if (rx > DEAD) want.add("e")
        if (maxOf(e.getAxisValue(MotionEvent.AXIS_RTRIGGER), e.getAxisValue(MotionEvent.AXIS_GAS)) > 0.5f) want.add(" ")
        if (maxOf(e.getAxisValue(MotionEvent.AXIS_LTRIGGER), e.getAxisValue(MotionEvent.AXIS_BRAKE)) > 0.5f) want.add("c")
        axes = want
        sync()
        return true
    }

    private fun sync() {
        var want = buttons + axes
        if (book()) {
            // menu opened it, so menu shuts it
            if ("o" in want) want = want + "Escape"
            want = want.filterTo(mutableSetOf()) { it in IN_BOOK }
        }
        for (k in held.toList()) if (k !in want) { held.remove(k); press(k, CODES.getValue(k), false) }
        for (k in want) if (k !in held) { held.add(k); press(k, CODES.getValue(k), true) }
    }

    /** Let go of everything, so nothing stays held in a world we've left. */
    private fun release() {
        buttons.clear()
        axes = emptySet()
        for (k in held.toList()) { held.remove(k); press(k, CODES.getValue(k), false) }
        for ((code, key) in typed.toList()) press(key, code, false)
        typed.clear()
    }

    private fun press(key: String, code: String, down: Boolean, repeat: Boolean = false) {
        val type = if (down) "keydown" else "keyup"
        web?.evaluateJavascript(
            "(function(){var t=document.querySelector('petrichor-64 canvas')||document.querySelector('canvas')||document.body;" +
                "t.dispatchEvent(new KeyboardEvent('$type',{key:${JSONObject.quote(key)},code:'$code',repeat:$repeat,bubbles:true}));})()",
            null,
        )
    }
}

/**
 * Touches on what's in this (a web view) stay its: once the web view has had
 * each one (children get them first in the main pass), they're marked used, so a gesture around
 * it, like the drawer's swipe, never takes a drag that started here. Swipes
 * elsewhere are untouched.
 */
fun Modifier.keepsTouches(): Modifier = pointerInput(Unit) {
    awaitPointerEventScope {
        while (true) {
            val e = awaitPointerEvent(PointerEventPass.Main)
            e.changes.forEach { it.consume() }
        }
    }
}
