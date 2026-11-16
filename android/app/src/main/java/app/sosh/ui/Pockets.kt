package app.sosh.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.animateOffsetAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.TextButton
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.input.pointer.isSecondaryPressed
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import app.sosh.AppState
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Backpack
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.min
import androidx.compose.ui.unit.sp
import app.sosh.data.Slot
import kotlin.math.roundToInt

/**
 * Something being dragged out of the pockets: which slot, where the finger
 * is (in root coordinates), and what it's over: another pocket (they sort),
 * the chat (it's wrapped as a present) or the world (the stack is dropped
 * there). Pockets, chat areas and the world say where they are as they're
 * laid out; the pockets panel too, since over it isn't the world.
 *
 * Before a drag, a pocket is pressed: it only tugs toward the finger
 * (`pressing`, `tug`) until the long press lifts it (`lifted`); moving on
 * from there drags it, letting go opens its menu. A mouse drags straight
 * away, and right-clicks for the menu.
 */
class PocketDrag {
    sealed interface Target {
        data class Pocket(val i: Int) : Target
        data object Chat : Target
        data object World : Target
    }

    var from by mutableStateOf<Int?>(null)
        private set
    var at by mutableStateOf(Offset.Zero)
        private set
    var over by mutableStateOf<Target?>(null)
        private set
    var pressing by mutableStateOf<Int?>(null)
        private set
    var tug by mutableStateOf(Offset.Zero)
        private set
    var lifted by mutableStateOf(false)
        private set
    var onDrop: (from: Int, to: Target) -> Unit = { _, _ -> }

    internal val pockets = HashMap<Int, Rect>()
    internal val chats = HashMap<String, Rect>()
    internal var world: Rect? = null
    internal var panel: Rect? = null

    fun press(i: Int) {
        pressing = i
        tug = Offset.Zero
        lifted = false
    }

    fun pull(by: Offset) {
        tug = by
    }

    fun lift() {
        lifted = true
        tug = Offset.Zero
    }

    fun release() {
        pressing = null
        tug = Offset.Zero
        lifted = false
    }

    fun start(i: Int, p: Offset) {
        release()
        from = i
        move(p)
    }

    fun move(p: Offset) {
        at = p
        over = pockets.entries.firstOrNull { it.value.contains(p) }?.let { Target.Pocket(it.key) }
            ?: if (chats.values.any { it.contains(p) }) Target.Chat
            else if (world?.contains(p) == true && panel?.contains(p) != true) Target.World
            else null
    }

    fun end() {
        val f = from
        val o = over
        cancel()
        if (f != null && o != null && o != Target.Pocket(f)) onDrop(f, o)
    }

    fun cancel() {
        from = null
        over = null
        release()
    }
}

/** This area takes a pocket dropped on it as a present for the chat. */
fun Modifier.chatTarget(drag: PocketDrag, key: String): Modifier = composed {
    DisposableEffect(drag, key) { onDispose { drag.chats.remove(key) } }
    onGloballyPositioned { drag.chats[key] = it.boundsInRoot() }
}

/** The world: a pocket dropped on it is set down there, the whole stack. */
fun Modifier.worldTarget(drag: PocketDrag): Modifier = composed {
    DisposableEffect(drag) { onDispose { drag.world = null } }
    onGloballyPositioned { drag.world = it.boundsInRoot() }
}

/** Something a pocket's menu offers. */
data class PocketAction(val label: String, val run: () -> Unit)

/**
 * The bag's slots as round pockets, eight to a row when they fit (as the
 * game lays them out), else four. Drag one onto another to sort them (like
 * stacks pour together, others swap), out onto the chat, or onto the world
 * to drop it; tap one to pick it; hold one (or right-click it) for its
 * menu: collect (marbles, into the wallet), whatever `extra` adds, split
 * and drop. Pockets of the item in hand (`held`) are ringed.
 */
@Composable
fun PocketGrid(
    app: AppState, drag: PocketDrag, held: String?, onTap: (Int) -> Unit,
    modifier: Modifier = Modifier, extra: (Int) -> List<PocketAction> = { emptyList() },
) {
    val bag = app.bag
    var menu by remember { mutableStateOf<Int?>(null) }
    var splitting by remember { mutableStateOf<Int?>(null) }
    fun actions(i: Int): List<PocketAction> {
        val s = bag.getOrNull(i) ?: return emptyList()
        val have = s.marbles ?: s.count
        return buildList {
            if (s.marbles != null) add(PocketAction("Collect") { app.deposit(i) })
            addAll(extra(i))
            if (have > 1) add(PocketAction("Split") { splitting = i })
            add(PocketAction("Drop") { app.bagDrop(i) })
        }
    }
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val gap = 6.dp
        val cols = if ((maxWidth - gap * 7) / 8 >= 36.dp) 8 else 4
        val size = min(56.dp, (maxWidth - gap * (cols - 1)) / cols)
        Column(verticalArrangement = Arrangement.spacedBy(gap + 2.dp)) {
            bag.indices.chunked(cols).forEach { row ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(gap, Alignment.CenterHorizontally)) {
                    row.forEach { i ->
                        Pocket(
                            i, bag[i], size, drag, held != null && bag[i]?.item == held, onTap,
                            menuOpen = menu == i, onMenu = { open -> menu = if (open) i else null },
                            actions = { actions(i) },
                        )
                    }
                }
            }
        }
    }
    splitting?.let { i ->
        val s = bag.getOrNull(i)
        if (s == null) splitting = null else SplitDialog(s, { splitting = null }) { n -> app.bagSplit(i, n); splitting = null }
    }
}

// How far a pressed pocket's insides tug toward the finger, at most, and
// how soon that gives out.
private val TugMax = 9.dp
private val TugSoft = 28.dp

private enum class Before { Tap, Cancel, Drag }

@Composable
private fun Pocket(
    i: Int, slot: Slot?, size: Dp, drag: PocketDrag, picked: Boolean, onTap: (Int) -> Unit,
    menuOpen: Boolean, onMenu: (Boolean) -> Unit, actions: () -> List<PocketAction>,
) {
    DisposableEffect(drag, i) { onDispose { drag.pockets.remove(i) } }
    // the gesture outlives recompositions: it calls whatever's current
    val tapNow by rememberUpdatedState(onTap)
    val menuNow by rememberUpdatedState(onMenu)
    val haptics = LocalHapticFeedback.current
    val density = LocalDensity.current
    val tugMax = with(density) { TugMax.toPx() }
    val tugSoft = with(density) { TugSoft.toPx() }
    val pressed = drag.pressing == i
    val longPress = LocalViewConfiguration.current.longPressTimeoutMillis
    // the tug: toward the finger, giving less the further it's pulled, and
    // springing back when let go
    val raw = if (pressed && !drag.lifted) drag.tug else Offset.Zero
    val d = raw.getDistance()
    val tugTo = if (d < 1f) Offset.Zero else raw * (tugMax / (d + tugSoft))
    val tug by animateOffsetAsState(tugTo, spring(dampingRatio = 0.5f, stiffness = Spring.StiffnessMedium), label = "tug")
    // swelling as the long press comes due, then up off the paper
    val swell by animateFloatAsState(
        when {
            pressed && drag.lifted -> 1.18f
            pressed -> 1.1f
            else -> 1f
        },
        if (pressed && !drag.lifted) tween(longPress.toInt()) else spring(dampingRatio = 0.45f),
        label = "swell",
    )
    val ring = when {
        drag.over == PocketDrag.Target.Pocket(i) -> Good
        pressed && drag.lifted -> Accent
        picked && drag.from == null -> Accent
        else -> null
    }
    Box(Modifier.size(size)) {
        Box(
            Modifier
                .matchParentSize()
                .onGloballyPositioned { drag.pockets[i] = it.boundsInRoot() }
                .drawBehind {
                    val r = this.size.minDimension / 2
                    drawCircle(PaperEdge, r, center.copy(y = center.y + 3.dp.toPx()))
                    drawCircle(Paper, r)
                    if (ring != null) drawCircle(ring, r + 1.dp.toPx(), style = Stroke(3.dp.toPx()))
                }
                .pointerInput(i, slot != null) {
                    if (slot == null) return@pointerInput
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        if (currentEvent.buttons.isSecondaryPressed) {
                            down.consume()
                            menuNow(true)
                            return@awaitEachGesture
                        }
                        val mouse = down.type == PointerType.Mouse
                        val slop = viewConfiguration.touchSlop
                        val origin = drag.pockets[i]?.topLeft ?: Offset.Zero
                        drag.press(i)
                        // before the long press: it only tugs (a mouse drags at once)
                        val before = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
                            var end = Before.Cancel
                            while (true) {
                                val c = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                                val moved = c.position - down.position
                                if (!c.pressed) {
                                    end = if (moved.getDistance() < slop) Before.Tap else Before.Cancel
                                    break
                                }
                                c.consume()
                                if (mouse && moved.getDistance() > slop) {
                                    end = Before.Drag
                                    break
                                }
                                drag.pull(moved)
                            }
                            end
                        }
                        var liftAt = down.position
                        when (before) {
                            Before.Tap -> {
                                drag.release()
                                tapNow(i)
                                return@awaitEachGesture
                            }
                            Before.Cancel -> {
                                drag.release()
                                return@awaitEachGesture
                            }
                            Before.Drag -> drag.start(i, origin + liftAt)
                            null -> {
                                // held: it lifts; moving on drags it, letting go
                                // opens its menu (once the finger's off, so the
                                // menu can't take the drag)
                                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                drag.lift()
                                liftAt = currentEvent.changes.firstOrNull { it.id == down.id }?.position ?: down.position
                                while (true) {
                                    val c = awaitPointerEvent().changes.firstOrNull { it.id == down.id }
                                    if (c == null) {
                                        drag.release()
                                        return@awaitEachGesture
                                    }
                                    if (!c.pressed) {
                                        drag.release()
                                        menuNow(true)
                                        return@awaitEachGesture
                                    }
                                    c.consume()
                                    if ((c.position - liftAt).getDistance() > slop) {
                                        drag.start(i, origin + c.position)
                                        break
                                    }
                                }
                            }
                        }
                        // dragging
                        while (true) {
                            val c = awaitPointerEvent().changes.firstOrNull { it.id == down.id }
                            if (c == null) {
                                drag.cancel()
                                break
                            }
                            if (!c.pressed) {
                                drag.end()
                                break
                            }
                            c.consume()
                            drag.move(origin + c.position)
                        }
                    }
                }
                .clip(CircleShape)
                .semantics {
                    role = Role.Button
                    if (slot != null) {
                        onClick(slot.item) { onTap(i); true }
                        onLongClick("options") { onMenu(true); true }
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            if (slot != null) {
                Box(
                    Modifier
                        .offset { IntOffset(tug.x.roundToInt(), tug.y.roundToInt()) }
                        .scale(swell)
                        .alpha(if (drag.from == i) 0.3f else 1f),
                ) { ItemIcon(slot.item, size * 0.56f) }
            }
        }
        if (slot != null && drag.from != i) {
            Text(
                slot.label, color = Paper, fontSize = 10.sp, fontWeight = FontWeight.ExtraBold,
                modifier = Modifier.align(Alignment.BottomEnd).offset(3.dp, 3.dp)
                    .offset { IntOffset(tug.x.roundToInt(), tug.y.roundToInt()) }
                    .background(Ink, RoundedCornerShape(10.dp)).padding(horizontal = 5.dp),
            )
        }
        DropdownMenu(menuOpen && slot != null, { onMenu(false) }) {
            if (slot != null) {
                Text(
                    slot.marbles?.let { "%,d marbles".format(it) } ?: "${slot.item} ×${slot.count}",
                    color = TextDim, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                )
            }
            actions().forEach { a ->
                DropdownMenuItem({ Text(a.label) }, { onMenu(false); a.run() })
            }
        }
    }
}

/** How many to take off a stack (or a bag of marbles) into a pocket of their own. */
@Composable
private fun SplitDialog(s: Slot, close: () -> Unit, split: (Int) -> Unit) {
    val have = s.marbles ?: s.count
    var text by remember(s) { mutableStateOf("${have / 2}") }
    val n = text.toIntOrNull()
    AlertDialog(
        onDismissRequest = close,
        title = { Text(if (s.marbles != null) "Split the bag of marbles" else "Split ${s.item}") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    text, { text = it.filter(Char::isDigit).take(6) },
                    label = { Text("How many off (of %,d)".format(have)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    TextButton({ text = "1" }) { Text("One") }
                    TextButton({ text = "${have / 2}" }) { Text("Half") }
                    TextButton({ text = "${have - 1}" }) { Text("All but one") }
                }
            }
        },
        confirmButton = { Button({ split(n!!) }, enabled = n != null && n in 1 until have) { Text("Split") } },
        dismissButton = { TextButton(close) { Text("Cancel") } },
    )
}

/**
 * The wallet: marbles kept out of the pockets. Bags of marbles go in whole
 * (each pocket's menu collects one; this, all of them); they come back out
 * a hundred, a thousand or however many at a time, into a bag of them.
 */
@Composable
fun WalletRow(app: AppState, modifier: Modifier = Modifier) {
    var choosing by remember { mutableStateOf(false) }
    var custom by remember { mutableStateOf(false) }
    val bags = app.bag.count { it?.marbles != null }
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Label("wallet", color = InkFaint)
            Text("%,d marbles".format(app.wallet), color = Ink, fontWeight = FontWeight.ExtraBold, fontSize = 16.sp)
        }
        if (bags > 0) TextButton({ app.depositAll() }) { Text("Collect $bags") }
        Box {
            TextButton({ choosing = true }, enabled = app.wallet > 0) { Text("Take out") }
            DropdownMenu(choosing, { choosing = false }) {
                listOf(100L, 1000L).forEach { n ->
                    DropdownMenuItem(
                        { Text("%,d".format(n)) },
                        { choosing = false; app.withdraw(n) },
                        enabled = app.wallet >= n,
                    )
                }
                DropdownMenuItem({ Text("Custom…") }, { choosing = false; custom = true })
            }
        }
    }
    if (custom) {
        var text by remember { mutableStateOf("") }
        val n = text.toLongOrNull()
        AlertDialog(
            onDismissRequest = { custom = false },
            title = { Text("Take marbles out") },
            text = {
                OutlinedTextField(
                    text, { text = it.filter(Char::isDigit).take(9) },
                    label = { Text("How many (you have %,d)".format(app.wallet)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton({ app.withdraw(n!!); custom = false }, enabled = n != null && n in 1..app.wallet) {
                    Text("Take out")
                }
            },
            dismissButton = { TextButton({ custom = false }) { Text("Cancel") } },
        )
    }
}

/**
 * The pockets, slid up over the bottom of the world from its backpack: the
 * world's bag. Tapping a pocket puts what's in it in hand; dragging sorts
 * them, gifts, or drops the stack in the world; holding one opens its menu.
 */
@Composable
fun PocketsPanel(
    app: AppState, drag: PocketDrag, held: String?, onHold: (String) -> Unit,
    open: Boolean, onClose: () -> Unit, modifier: Modifier = Modifier,
) {
    val bag = app.bag
    DisposableEffect(drag) { onDispose { drag.panel = null } }
    AnimatedVisibility(open, modifier, enter = slideInVertically { it + 40 }, exit = slideOutVertically { it + 40 }) {
        Column(
            Modifier.fillMaxWidth().padding(8.dp)
                .onGloballyPositioned { drag.panel = it.boundsInRoot() }
                .paper(drop = 4.dp).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Label("pockets ${bag.count { it != null }}/${bag.size}", color = InkFaint)
                    val n = held?.let { h -> bag.sumOf { if (it?.item == h) it.count else 0 } } ?: 0
                    Text(
                        if (n > 0) "In hand: $held ×$n" else "Tap to hold, hold for more, drag to sort, gift or drop",
                        color = Ink, fontWeight = FontWeight.ExtraBold, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
                PlasticButton(onClose, Modifier.size(44.dp), tone = Tone.Green, shape = RoundedCornerShape(14.dp)) {
                    Icon(Icons.Filled.ExpandMore, "close pockets")
                }
            }
            Box(Modifier.background(PaperDeep, RoundedCornerShape(18.dp)).padding(horizontal = 6.dp, vertical = 10.dp)) {
                PocketGrid(app, drag, held, { i -> bag.getOrNull(i)?.let { onHold(it.item) } })
            }
            WalletRow(app, Modifier.padding(horizontal = 6.dp))
        }
    }
}

/** The world's backpack: tap it, or drag it up, for the pockets. */
@Composable
fun BackpackButton(filled: Int, onOpen: () -> Unit, modifier: Modifier = Modifier) {
    val lift = with(LocalDensity.current) { 16.dp.toPx() }
    Box(modifier) {
        PlasticButton(
            onOpen,
            Modifier.size(56.dp).pointerInput(Unit) {
                var dy = 0f
                detectVerticalDragGestures(onDragStart = { dy = 0f }) { change, d ->
                    change.consume()
                    dy += d
                    if (dy < -lift) {
                        dy = Float.NEGATIVE_INFINITY
                        onOpen()
                    }
                }
            },
            tone = Tone.Green, shape = RoundedCornerShape(18.dp),
        ) { Icon(Icons.Filled.Backpack, "pockets", Modifier.size(28.dp)) }
        Text(
            "$filled", color = Ink, fontSize = 11.sp, fontWeight = FontWeight.ExtraBold,
            modifier = Modifier.align(Alignment.TopEnd).offset(4.dp, (-4).dp).background(Paper, RoundedCornerShape(10.dp)).padding(horizontal = 6.dp),
        )
    }
}

/** What's being dragged, under the finger, over everything. */
@Composable
fun DragGhost(bag: List<Slot?>, drag: PocketDrag, origin: Offset) {
    val i = drag.from ?: return
    val slot = bag.getOrNull(i) ?: return
    val half = with(LocalDensity.current) { 32.dp.toPx() }
    Box(
        Modifier
            .offset { IntOffset((drag.at.x - origin.x - half).roundToInt(), (drag.at.y - origin.y - half * 1.6f).roundToInt()) }
            .size(64.dp)
            .rotate(-6f)
            .scale(1.05f)
            .drawBehind {
                val r = size.minDimension / 2
                drawCircle(Color(0x66000000), r, center.copy(y = center.y + 8.dp.toPx()))
                drawCircle(Paper, r)
                drawCircle(if (drag.over != null) Good else Accent, r, style = Stroke(3.dp.toPx()))
            },
        contentAlignment = Alignment.Center,
    ) {
        ItemIcon(slot.item, 34.dp)
        Text(
            slot.label, color = Paper, fontSize = 11.sp, fontWeight = FontWeight.ExtraBold,
            modifier = Modifier.align(Alignment.BottomEnd).background(Ink, RoundedCornerShape(10.dp)).padding(horizontal = 6.dp),
        )
    }
}
