package app.sosh.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
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
import androidx.compose.runtime.remember
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
 * is (in root coordinates), and what it's over: another pocket (they swap)
 * or the chat (it's wrapped as a present). Pockets and chat areas say where
 * they are as they're laid out.
 */
class PocketDrag {
    sealed interface Target {
        data class Pocket(val i: Int) : Target
        data object Chat : Target
    }

    var from by mutableStateOf<Int?>(null)
        private set
    var at by mutableStateOf(Offset.Zero)
        private set
    var over by mutableStateOf<Target?>(null)
        private set
    var onDrop: (from: Int, to: Target) -> Unit = { _, _ -> }

    internal val pockets = HashMap<Int, Rect>()
    internal val chats = HashMap<String, Rect>()

    fun start(i: Int, p: Offset) {
        from = i
        move(p)
    }

    fun move(p: Offset) {
        at = p
        over = pockets.entries.firstOrNull { it.value.contains(p) }?.let { Target.Pocket(it.key) }
            ?: if (chats.values.any { it.contains(p) }) Target.Chat else null
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
    }
}

/** This area takes a pocket dropped on it as a present for the chat. */
fun Modifier.chatTarget(drag: PocketDrag, key: String): Modifier = composed {
    DisposableEffect(drag, key) { onDispose { drag.chats.remove(key) } }
    onGloballyPositioned { drag.chats[key] = it.boundsInRoot() }
}

/**
 * The bag's slots as round pockets, eight to a row when they fit (as the
 * game lays them out), else four. Drag one onto another to swap them, or
 * out onto the chat; tap one to pick it.
 */
@Composable
fun PocketGrid(bag: List<Slot?>, drag: PocketDrag, picked: Int?, onTap: (Int) -> Unit, modifier: Modifier = Modifier) {
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val gap = 6.dp
        val cols = if ((maxWidth - gap * 7) / 8 >= 36.dp) 8 else 4
        val size = min(56.dp, (maxWidth - gap * (cols - 1)) / cols)
        Column(verticalArrangement = Arrangement.spacedBy(gap + 2.dp)) {
            bag.indices.chunked(cols).forEach { row ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(gap, Alignment.CenterHorizontally)) {
                    row.forEach { i -> Pocket(i, bag[i], size, drag, picked == i, onTap) }
                }
            }
        }
    }
}

@Composable
private fun Pocket(i: Int, slot: Slot?, size: Dp, drag: PocketDrag, picked: Boolean, onTap: (Int) -> Unit) {
    DisposableEffect(drag, i) { onDispose { drag.pockets.remove(i) } }
    val ring = when {
        drag.over == PocketDrag.Target.Pocket(i) -> Good
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
                    detectDragGestures(
                        onDragStart = { o -> drag.start(i, (drag.pockets[i]?.topLeft ?: Offset.Zero) + o) },
                        onDrag = { change, _ ->
                            change.consume()
                            drag.move((drag.pockets[i]?.topLeft ?: Offset.Zero) + change.position)
                        },
                        onDragEnd = { drag.end() },
                        onDragCancel = { drag.cancel() },
                    )
                }
                .clip(CircleShape)
                .clickable(enabled = slot != null, role = Role.Button, onClickLabel = slot?.item) { onTap(i) },
            contentAlignment = Alignment.Center,
        ) {
            if (slot != null) {
                Box(Modifier.alpha(if (drag.from == i) 0.3f else 1f)) { ItemIcon(slot.item, size * 0.56f) }
            }
        }
        if (slot != null && drag.from != i) {
            Text(
                "${slot.count}", color = Paper, fontSize = 10.sp, fontWeight = FontWeight.ExtraBold,
                modifier = Modifier.align(Alignment.BottomEnd).offset(3.dp, 3.dp)
                    .background(Ink, RoundedCornerShape(10.dp)).padding(horizontal = 5.dp),
            )
        }
    }
}

/**
 * The pockets, slid up over the bottom of the world from its backpack.
 * Tapping a pocket says what's in it; dragging sorts them or gifts.
 */
@Composable
fun PocketsPanel(bag: List<Slot?>, drag: PocketDrag, open: Boolean, onClose: () -> Unit, modifier: Modifier = Modifier) {
    var picked by remember { mutableStateOf<Int?>(null) }
    AnimatedVisibility(open, modifier, enter = slideInVertically { it + 40 }, exit = slideOutVertically { it + 40 }) {
        Column(
            Modifier.fillMaxWidth().padding(8.dp).paper(drop = 4.dp).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Label("pockets ${bag.count { it != null }}/${bag.size}", color = InkFaint)
                    val s = picked?.let { bag.getOrNull(it) }
                    Text(
                        if (s != null) "${s.item} ×${s.count}" else "Drag to sort, or into the chat to gift",
                        color = Ink, fontWeight = FontWeight.ExtraBold, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
                PlasticButton(onClose, Modifier.size(44.dp), tone = Tone.Green, shape = RoundedCornerShape(14.dp)) {
                    Icon(Icons.Filled.ExpandMore, "close pockets")
                }
            }
            Box(Modifier.background(PaperDeep, RoundedCornerShape(18.dp)).padding(horizontal = 6.dp, vertical = 10.dp)) {
                PocketGrid(bag, drag, picked, { picked = it })
            }
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
            "${slot.count}", color = Paper, fontSize = 11.sp, fontWeight = FontWeight.ExtraBold,
            modifier = Modifier.align(Alignment.BottomEnd).background(Ink, RoundedCornerShape(10.dp)).padding(horizontal = 6.dp),
        )
    }
}
