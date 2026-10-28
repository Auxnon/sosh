package app.sosh.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.sosh.AppState
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.hypot

val COLORS = listOf(
    "FFDBAC", "F1C27D", "E8B796", "C68642", "8D5524", "4A3020",
    "302820", "F4F0E6", "A8B0BC", "40404A", "C04040", "E07040",
    "E0C040", "40A060", "4F7FC0", "8050C0", "E04080", "6A4A30",
)

/**
 * How someone looks (the server's `Sosh.Character`): height, skin, head,
 * hair, clothes and a hat, each with a colour; and the face, a list of
 * sprites placed across the front of the head. The preview is drawn from
 * the front. Drag a face sprite to move it; tap one to pick it.
 */
@Composable
fun CreatorScreen(app: AppState, back: () -> Unit) {
    val start = remember { JSONObject((app.me?.character ?: JSONObject()).toString()) }
    var spec by remember { mutableStateOf(start) }
    var version by remember { mutableIntStateOf(0) }
    var picked by remember { mutableIntStateOf(-1) }
    var tab by remember { mutableIntStateOf(0) }
    fun changed() { version++ }

    Page("Your look", back) {
        // read `version` so edits redraw
        val v = version
        Box(Modifier.fillMaxWidth().height(300.dp).background(Color(0xFF6F98C8)), contentAlignment = Alignment.Center) {
            Preview(spec, picked, v, onPick = { picked = it }, onMove = { i, dx, dy ->
                val p = spec.getJSONArray("face").getJSONObject(i)
                p.put("x", (p.optDouble("x") + dx).coerceIn(-1.0, 1.0))
                p.put("y", (p.optDouble("y") + dy).coerceIn(-1.0, 1.0))
                changed()
            })
        }
        TabRow(tab, containerColor = Panel) {
            Tab(tab == 0, { tab = 0 }, text = { Text("Body") })
            Tab(tab == 1, { tab = 1 }, text = { Text("Face") })
        }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(12.dp)) {
            if (tab == 0) BodyControls(app, spec) { changed() }
            else FaceControls(app, spec, picked, { picked = it }) { changed() }
        }
        Row(Modifier.fillMaxWidth().padding(12.dp), horizontalArrangement = Arrangement.End) {
            TextButton(back) { Text("Cancel") }
            Button({ app.saveCharacter(spec) { back() } }) { Text("Save") }
        }
    }
}

@Composable
private fun BodyControls(app: AppState, spec: JSONObject, changed: () -> Unit) {
    val cat = app.catalog
    Text("Height ${(spec.optDouble("height", 1.0) * 100).toInt()}%", color = TextDim)
    Slider(
        spec.optDouble("height", 1.0).toFloat(), { spec.put("height", it.toDouble()); changed() },
        valueRange = 0.85f..1.2f,
    )
    Text("Skin", color = TextDim)
    Swatches(spec.optString("skin")) { spec.put("skin", it); changed() }
    Option("Head", cat.heads, spec.optString("head", "round")) { spec.put("head", it); changed() }
    Option("Hair", cat.hair, spec.optString("hair", "none")) { spec.put("hair", it); changed() }
    Swatches(spec.optString("hair_color")) { spec.put("hair_color", it); changed() }
    for (slot in listOf("top", "bottom", "shoes", "hat")) {
        Option(slot.replaceFirstChar { it.uppercase() }, cat.clothes[slot] ?: listOf("none"), spec.optString(slot, "none")) {
            spec.put(slot, it); changed()
        }
        Swatches(spec.optString("${slot}_color")) { spec.put("${slot}_color", it); changed() }
    }
}

@Composable
private fun Option(title: String, options: List<String>, value: String, pick: (String) -> Unit) {
    Text(title, color = TextDim, modifier = Modifier.padding(top = 10.dp))
    ChipFlow(options, value, label = { it }, pick = pick)
}

@Composable
private fun Swatches(selected: String, pick: (String) -> Unit) {
    Column {
        COLORS.chunked(9).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(vertical = 3.dp)) {
                row.forEach { c ->
                    Surface(
                        onClick = { pick(c) },
                        shape = CircleShape,
                        color = hex(c),
                        border = if (c.equals(selected, ignoreCase = true)) androidx.compose.foundation.BorderStroke(2.dp, Accent) else null,
                        modifier = Modifier.size(28.dp),
                    ) {}
                }
            }
        }
    }
}

@Composable
private fun FaceControls(app: AppState, spec: JSONObject, picked: Int, pick: (Int) -> Unit, changed: () -> Unit) {
    val face = spec.optJSONArray("face") ?: JSONArray().also { spec.put("face", it) }
    val parts = app.catalog.parts
    Text("Add", color = TextDim)
    ChipFlow(parts.keys.toList(), null, label = { "+ $it" }) { part ->
        if (face.length() < app.catalog.maxFace) {
            face.put(
                JSONObject().put("part", part).put("shape", 0).put("x", 0.0).put("y", 0.0)
                    .put("scale", 1.0).put("rot", 0.0).put("color", "302820")
            )
            pick(face.length() - 1)
            changed()
        }
    }
    Text("Drag a part on the face to move it. Tap one to pick it.", color = TextDim, fontSize = 12.sp, modifier = Modifier.padding(vertical = 6.dp))
    val labels = (0 until face.length()).map { i -> "${face.getJSONObject(i).optString("part")} ${i + 1}" }
    ChipFlow(labels.indices.toList(), picked.takeIf { it >= 0 }, label = { labels[it] }) { pick(if (it == picked) -1 else it) }
    if (picked in 0 until face.length()) {
        val p = face.getJSONObject(picked)
        val n = parts[p.optString("part")] ?: 1
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Shape ${p.optInt("shape") + 1} of $n", modifier = Modifier.weight(1f))
            TextButton({ p.put("shape", (p.optInt("shape") - 1 + n) % n); changed() }) { Text("‹") }
            TextButton({ p.put("shape", (p.optInt("shape") + 1) % n); changed() }) { Text("›") }
        }
        Text("Size", color = TextDim)
        Slider(p.optDouble("scale", 1.0).toFloat(), { p.put("scale", it.toDouble()); changed() }, valueRange = 0.4f..2.5f)
        Text("Turn", color = TextDim)
        Slider(p.optDouble("rot", 0.0).toFloat(), { p.put("rot", it.toDouble()); changed() }, valueRange = -3.14f..3.14f)
        Swatches(p.optString("color")) { p.put("color", it); changed() }
        TextButton({ face.remove(picked); pick(-1); changed() }) { Text("Remove", color = Bad) }
    }
}

// -- the preview

private data class Head(val face: Rect, val bounds: Rect)

/** The character from the front; face sprites draggable. */
@Composable
private fun Preview(
    spec: JSONObject,
    picked: Int,
    version: Int,
    onPick: (Int) -> Unit,
    onMove: (Int, Double, Double) -> Unit,
) {
    // where the head was last drawn: read by the gestures, not drawn from
    val head = remember { arrayOfNulls<Head>(1) }
    var dragging by remember { mutableIntStateOf(-1) }
    val face = spec.optJSONArray("face") ?: JSONArray()

    fun nearest(at: Offset): Int {
        val h = head[0] ?: return -1
        var best = -1
        var bestD = Float.MAX_VALUE
        for (i in 0 until face.length()) {
            val p = face.getJSONObject(i)
            val c = spriteCentre(h.face, p)
            val d = hypot(c.x - at.x, c.y - at.y)
            if (d < bestD && d < h.face.width * 0.35f) {
                bestD = d
                best = i
            }
        }
        return best
    }

    Canvas(
        Modifier.size(260.dp, 300.dp)
            .pointerInput(version) {
                detectTapGestures { onPick(nearest(it)) }
            }
            .pointerInput(version) {
                detectDragGestures(
                    onDragStart = { dragging = nearest(it); if (dragging >= 0) onPick(dragging) },
                    onDragEnd = { dragging = -1 },
                    onDrag = { change, d ->
                        val h = head[0]
                        if (dragging >= 0 && h != null) {
                            change.consume()
                            onMove(dragging, (d.x / (h.face.width / 2)).toDouble(), (-d.y / (h.face.height / 2)).toDouble())
                        }
                    },
                )
            }
    ) {
        @Suppress("UNUSED_EXPRESSION") version
        head[0] = drawCharacter(spec, picked)
    }
}

private fun spriteCentre(face: Rect, p: JSONObject): Offset = Offset(
    face.center.x + p.optDouble("x").toFloat() * face.width / 2,
    face.center.y - p.optDouble("y").toFloat() * face.height / 2,
)

/** Draws everything; returns where the head and its face are. */
private fun DrawScope.drawCharacter(spec: JSONObject, picked: Int): Head {
    val k = spec.optDouble("height", 1.0).toFloat()
    val skin = hex(spec.optString("skin"), Color(0xFFE8B796))
    val unit = size.height / 2.4f
    val cx = size.width / 2
    val floor = size.height - 8
    val legH = unit * 0.38f * k
    val bodyH = unit * 0.48f * k
    val hip = floor - legH
    val shoulder = hip - bodyH
    val bw = unit * 0.36f

    // legs and shoes
    val bottom = spec.optString("bottom", "none")
    val legColor = if (bottom == "pants") hex(spec.optString("bottom_color")) else skin
    for (side in listOf(-1, 1)) {
        drawRect(legColor, Offset(cx + side * bw * 0.28f - bw * 0.14f, hip), Size(bw * 0.28f, legH))
        if (spec.optString("shoes", "none") != "none") {
            val shoeH = if (spec.optString("shoes") == "boots") legH * 0.4f else legH * 0.16f
            drawRect(hex(spec.optString("shoes_color")), Offset(cx + side * bw * 0.28f - bw * 0.17f, floor - shoeH), Size(bw * 0.34f, shoeH))
        }
    }
    when (bottom) {
        "shorts" -> drawRect(hex(spec.optString("bottom_color")), Offset(cx - bw / 2, hip - 4), Size(bw, legH * 0.42f))
        "skirt" -> {
            val path = Path().apply {
                moveTo(cx - bw / 2, hip - 6); lineTo(cx + bw / 2, hip - 6)
                lineTo(cx + bw * 0.75f, hip + legH * 0.5f); lineTo(cx - bw * 0.75f, hip + legH * 0.5f); close()
            }
            drawPath(path, hex(spec.optString("bottom_color")))
        }
    }
    // body and arms
    val top = spec.optString("top", "none")
    val shirt = if (top == "none") skin else hex(spec.optString("top_color"))
    val longSleeves = top == "jacket" || top == "sweater"
    for (side in listOf(-1, 1)) {
        val ax = cx + side * (bw / 2 + bw * 0.1f)
        drawRoundRect(if (longSleeves) shirt else skin, Offset(ax - bw * 0.1f, shoulder + 2), Size(bw * 0.2f, bodyH * 0.95f), CornerRadius(6f))
        if (!longSleeves && top != "none") drawRect(shirt, Offset(ax - bw * 0.1f, shoulder + 2), Size(bw * 0.2f, bodyH * 0.3f))
        drawCircle(skin, bw * 0.11f, Offset(ax, shoulder + bodyH))
    }
    drawRoundRect(shirt, Offset(cx - bw / 2, shoulder), Size(bw, bodyH + 4), CornerRadius(10f))
    if (top == "jacket") drawLine(Color.Black.copy(alpha = 0.25f), Offset(cx, shoulder + 4), Offset(cx, hip), 3f)

    // head
    val neck = shoulder - 2
    val hs = unit * 0.5f
    val headName = spec.optString("head", "round")
    val (hw, hh) = when (headName) {
        "square" -> hs * 0.92f to hs * 0.96f
        "long" -> hs * 0.8f to hs * 1.25f
        "bean" -> hs * 1.12f to hs * 0.82f
        else -> hs to hs
    }
    val bounds = Rect(cx - hw / 2, neck - hh, cx + hw / 2, neck)
    when (headName) {
        "square" -> drawRoundRect(skin, bounds.topLeft, bounds.size, CornerRadius(6f))
        else -> drawOval(skin, bounds.topLeft, bounds.size)
    }
    // hair over the top of the head (behind the face sprites)
    val hairName = spec.optString("hair", "none")
    if (hairName != "none") {
        val hc = hex(spec.optString("hair_color"))
        val capTop = bounds.top - hh * 0.06f
        drawArc(hc, 180f, 180f, true, Offset(bounds.left - 3, capTop), Size(bounds.width + 6, hh * 0.62f))
        when (hairName) {
            "tuft" -> drawPath(Path().apply { moveTo(cx - 6, capTop + 2); lineTo(cx + 2, capTop - hh * 0.25f); lineTo(cx + 8, capTop + 2); close() }, hc)
            "spikes" -> for (i in -2..2) drawPath(Path().apply {
                val x = cx + i * hw * 0.18f
                moveTo(x - 7, capTop + 6); lineTo(x, capTop - hh * 0.2f); lineTo(x + 7, capTop + 6); close()
            }, hc)
            "bob" -> for (side in listOf(-1, 1)) drawRect(hc, Offset(if (side < 0) bounds.left - 4 else bounds.right - hw * 0.14f + 4, bounds.top + hh * 0.2f), Size(hw * 0.14f, hh * 0.7f))
            "long" -> for (side in listOf(-1, 1)) drawRect(hc, Offset(if (side < 0) bounds.left - 5 else bounds.right - hw * 0.12f + 5, bounds.top + hh * 0.2f), Size(hw * 0.12f, hh * 1.4f))
        }
    }
    val hat = spec.optString("hat", "none")
    if (hat != "none") {
        val c = hex(spec.optString("hat_color"))
        when (hat) {
            "cap" -> {
                drawArc(c, 180f, 180f, true, Offset(bounds.left - 2, bounds.top - hh * 0.08f), Size(bounds.width + 4, hh * 0.6f))
                drawRect(c, Offset(cx, bounds.top + hh * 0.2f), Size(hw * 0.7f, 6f))
            }
            "beanie" -> {
                drawArc(c, 180f, 180f, true, Offset(bounds.left - 4, bounds.top - hh * 0.1f), Size(bounds.width + 8, hh * 0.75f))
                drawCircle(c, 8f, Offset(cx, bounds.top - hh * 0.12f))
            }
            "tophat" -> {
                drawRect(c, Offset(bounds.left - 12, bounds.top + 2), Size(bounds.width + 24, 7f))
                drawRect(c, Offset(cx - hw * 0.32f, bounds.top - hh * 0.6f), Size(hw * 0.64f, hh * 0.64f))
            }
        }
    }

    // the face: sprites across the front of the head (the client's
    // character_rig.lua spans, in head-sized units)
    val faceRect = when (headName) {
        "square" -> Rect(cx - hw * 0.42f, bounds.top + hh * 0.08f, cx + hw * 0.42f, bounds.bottom - hh * 0.08f)
        "long" -> Rect(cx - hw * 0.38f, bounds.top + hh * 0.1f, cx + hw * 0.38f, bounds.bottom - hh * 0.06f)
        "bean" -> Rect(cx - hw * 0.43f, bounds.top + hh * 0.12f, cx + hw * 0.43f, bounds.bottom - hh * 0.12f)
        else -> Rect(cx - hw * 0.4f, bounds.top + hh * 0.1f, cx + hw * 0.4f, bounds.bottom - hh * 0.1f)
    }
    val face = spec.optJSONArray("face") ?: JSONArray()
    for (i in 0 until face.length()) {
        val p = face.getJSONObject(i)
        val c = spriteCentre(faceRect, p)
        val s = faceRect.width * 0.65f * p.optDouble("scale", 1.0).toFloat()
        val deg = Math.toDegrees(-p.optDouble("rot", 0.0)).toFloat()
        rotate(deg, c) {
            sprite(p.optString("part"), p.optInt("shape"), hex(p.optString("color"), Color.DarkGray), Rect(c.x - s / 2, c.y - s / 2, c.x + s / 2, c.y + s / 2))
        }
        if (i == picked) drawCircle(Accent, s * 0.6f, c, style = Stroke(2f))
    }
    return Head(faceRect, bounds)
}

/**
 * A face sprite in `r`, drawn as tools/gen_character.py draws it on its
 * 32px square (coordinates here are in that square's units).
 */
private fun DrawScope.sprite(part: String, shape: Int, color: Color, r: Rect) {
    val u = r.width / 32f
    fun o(x: Float, y: Float) = Offset(r.left + x * u, r.top + y * u)
    fun box(x0: Float, y0: Float, x1: Float, y1: Float) = Pair(o(x0, y0), Size((x1 - x0) * u, (y1 - y0) * u))
    fun oval(x0: Float, y0: Float, x1: Float, y1: Float) { val (a, b) = box(x0, y0, x1, y1); drawOval(color, a, b) }
    fun rect(x0: Float, y0: Float, x1: Float, y1: Float) { val (a, b) = box(x0, y0, x1, y1); drawRect(color, a, b) }
    fun line(x0: Float, y0: Float, x1: Float, y1: Float, w: Float) = drawLine(color, o(x0, y0), o(x1, y1), w * u)
    fun arc(x0: Float, y0: Float, x1: Float, y1: Float, start: Float, end: Float, w: Float) {
        val (a, b) = box(x0, y0, x1, y1)
        drawArc(color, start, end - start, false, a, b, style = Stroke(w * u))
    }
    fun poly(vararg pts: Float) {
        val p = Path()
        p.moveTo(r.left + pts[0] * u, r.top + pts[1] * u)
        var i = 2
        while (i < pts.size) { p.lineTo(r.left + pts[i] * u, r.top + pts[i + 1] * u); i += 2 }
        p.close()
        drawPath(p, color)
    }
    when (part) {
        "eye" -> when (shape) {
            0 -> oval(10f, 9f, 22f, 23f)
            1 -> oval(8f, 12f, 24f, 20f)
            2 -> rect(13f, 8f, 19f, 24f)
            3 -> arc(7f, 10f, 25f, 26f, 200f, 340f, 4f)
            4 -> { val (a, b) = box(9f, 9f, 23f, 23f); drawOval(color, a, b, style = Stroke(3f * u)) }
            else -> line(8f, 16f, 24f, 16f, 4f)
        }
        "brow" -> when (shape) {
            0 -> rect(6f, 14f, 26f, 18f)
            1 -> line(6f, 19f, 26f, 13f, 4f)
            2 -> arc(6f, 12f, 26f, 28f, 200f, 340f, 4f)
            else -> poly(6f, 18f, 16f, 12f, 26f, 18f, 26f, 20f, 16f, 15f, 6f, 20f)
        }
        "mouth" -> when (shape) {
            0 -> arc(6f, 2f, 26f, 22f, 20f, 160f, 3f)
            1 -> line(8f, 16f, 24f, 16f, 3f)
            2 -> oval(11f, 10f, 21f, 22f)
            3 -> { val (a, b) = box(6f, 4f, 26f, 24f); drawArc(color, 0f, 180f, true, a, b) }
            4 -> arc(6f, 12f, 26f, 32f, 200f, 340f, 3f)
            else -> { line(8f, 14f, 12f, 18f, 2f); line(12f, 18f, 16f, 14f, 2f); line(16f, 14f, 20f, 18f, 2f); line(20f, 18f, 24f, 14f, 2f) }
        }
        "nose" -> when (shape) {
            0 -> oval(12f, 12f, 20f, 20f)
            1 -> poly(16f, 8f, 21f, 22f, 11f, 22f)
            2 -> line(16f, 8f, 14f, 22f, 3f)
            else -> { oval(10f, 15f, 14f, 19f); oval(18f, 15f, 22f, 19f) }
        }
        "cheek" -> when (shape) {
            0 -> { val (a, b) = box(4f, 9f, 28f, 23f); drawOval(color.copy(alpha = 0.8f), a, b) }
            else -> { line(6f, 12f, 12f, 20f, 2f); line(13f, 12f, 19f, 20f, 2f); line(20f, 12f, 26f, 20f, 2f) }
        }
        "mark" -> when (shape) {
            0 -> { oval(8f, 10f, 12f, 14f); oval(16f, 16f, 20f, 20f); oval(22f, 9f, 26f, 13f) }
            1 -> poly(16f, 4f, 19f, 13f, 28f, 13f, 21f, 19f, 24f, 28f, 16f, 22f, 8f, 28f, 11f, 19f, 4f, 13f, 13f, 13f)
            2 -> poly(16f, 26f, 5f, 14f, 9f, 7f, 16f, 12f, 23f, 7f, 27f, 14f)
            else -> line(8f, 8f, 24f, 24f, 3f)
        }
    }
}
