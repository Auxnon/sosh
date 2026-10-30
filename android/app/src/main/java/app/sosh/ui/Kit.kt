package app.sosh.ui

import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.addOutline
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.res.imageResource
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.sosh.R

/** The indigo ground with its faint grid, behind every screen. */
fun Modifier.ground(cell: Dp = 26.dp) = drawBehind {
    drawRect(Night)
    val step = cell.toPx()
    var x = 0f
    while (x < size.width) {
        drawLine(Grid, Offset(x, 0f), Offset(x, size.height), 1f)
        x += step
    }
    var y = 0f
    while (y < size.height) {
        drawLine(Grid, Offset(0f, y), Offset(size.width, y), 1f)
        y += step
    }
}

/**
 * Chunky console plastic: `color` with a light line along its top edge and
 * a solid `edge` under it, so it looks like it would press in.
 */
fun Modifier.plastic(
    shape: Shape = RoundedCornerShape(22.dp),
    color: Color = Panel,
    edge: Color = Edge,
    drop: Dp = 4.dp,
    shine: Float = 0.2f,
) = drawBehind {
    val o = shape.createOutline(size, layoutDirection, this)
    translate(top = drop.toPx()) { drawOutline(o, edge) }
    drawOutline(o, color)
    if (shine > 0f) {
        clipPath(Path().apply { addOutline(o) }) {
            drawRect(Color.White.copy(alpha = shine), size = Size(size.width, 2.dp.toPx()))
        }
    }
}

/** Paper: a cream card with a solid shadow under it. */
fun Modifier.paper(shape: Shape = RoundedCornerShape(22.dp), color: Color = Paper, edge: Color = Edge, drop: Dp = 4.dp) =
    plastic(shape, color, edge, drop, shine = 0f)

enum class Tone(val color: Color, val edge: Color, val on: Color) {
    Plastic(PanelHi, Edge, TextMain),
    Orange(Accent, AccentEdge, OnAccent),
    Green(Good, GoodEdge, OnGood),
}

/** A pressable plastic button (at least 44dp, for fingers). */
@Composable
fun PlasticButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tone: Tone = Tone.Plastic,
    shape: Shape = RoundedCornerShape(16.dp),
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    val t = if (enabled) tone else Tone.Plastic
    Row(
        modifier
            .defaultMinSize(44.dp, 44.dp)
            .plastic(shape, t.color, t.edge, drop = 3.dp, shine = if (tone == Tone.Plastic) 0.25f else 0.4f)
            .clip(shape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        androidx.compose.runtime.CompositionLocalProvider(
            androidx.compose.material3.LocalContentColor provides if (enabled) t.on else TextDim,
        ) { content() }
    }
}

/** A plain bordered button on paper. */
@Composable
fun PaperButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(16.dp)
    Box(
        modifier
            .defaultMinSize(44.dp, 44.dp)
            .clip(shape)
            .background(Color.Transparent)
            .drawBehind {
                val o = shape.createOutline(size, layoutDirection, this)
                drawOutline(o, PaperEdge, style = androidx.compose.ui.graphics.drawscope.Stroke(2.dp.toPx()))
            }
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp),
        contentAlignment = Alignment.Center,
    ) { Text(text, color = Ink, fontWeight = FontWeight.Bold, fontSize = 15.sp) }
}

/** A cream card. */
@Composable
fun PaperCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.paper().padding(16.dp), content = content)
}

/** Someone's name on a tilted pastel tag, as over a speech bubble. */
@Composable
fun NameTag(handle: String, modifier: Modifier = Modifier, tilt: Float = -3f, size: Int = 13) {
    Text(
        handle, color = Color(0xFF3A2C1C), fontWeight = FontWeight.ExtraBold, fontSize = size.sp,
        modifier = modifier.rotate(tilt).background(handleColor(handle), RoundedCornerShape(12.dp)).padding(horizontal = 11.dp, vertical = 2.dp),
    )
}

/** Small wide capitals: the console's labels. */
@Composable
fun Label(text: String, modifier: Modifier = Modifier, color: Color = TextDim, style: TextStyle = TechLabel) {
    Text(text.uppercase(), modifier, color = color, style = style)
}

@DrawableRes
private fun iconOf(item: String): Int? = when (item) {
    "grass" -> R.drawable.item_grass
    "dirt" -> R.drawable.item_dirt
    "stone" -> R.drawable.item_stone
    "wood" -> R.drawable.item_wood
    "path" -> R.drawable.item_path
    "deck" -> R.drawable.item_deck
    "hull" -> R.drawable.item_hull
    "balloon" -> R.drawable.item_balloon
    "rail" -> R.drawable.item_rail
    "helm" -> R.drawable.item_helm
    "pot" -> R.drawable.item_pot
    "carrot" -> R.drawable.item_carrot
    "drawer" -> R.drawable.item_drawer
    "stool" -> R.drawable.item_stool
    else -> null
}

/** An item as the game draws it: its pixel icon, or a lettered tile. */
@Composable
fun ItemIcon(item: String, size: Dp, modifier: Modifier = Modifier) {
    val id = iconOf(item)
    if (id != null) {
        Image(
            ImageBitmap.imageResource(id), item, modifier.size(size).clip(RoundedCornerShape(size / 5)),
            filterQuality = FilterQuality.None,
        )
    } else {
        Box(modifier.size(size).background(handleColor(item), RoundedCornerShape(size / 4)), contentAlignment = Alignment.Center) {
            Text(item.take(1).uppercase(), color = Ink, fontWeight = FontWeight.ExtraBold, fontSize = (size.value * 0.5f).sp)
        }
    }
}
