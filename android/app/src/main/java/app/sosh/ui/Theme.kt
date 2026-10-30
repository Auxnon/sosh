package app.sosh.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import app.sosh.R

// A console's boot menu around cozy paper: indigo plastic with a faint
// grid, cream speech bubbles in brown ink, leaf green and orange.
val Night = Color(0xFF241E4E) // the ground, behind everything
val Grid = Color(0xFF2C2660) // its faint grid lines
val Panel = Color(0xFF3B3380) // plastic: bars, trays, the rail
val PanelHi = Color(0xFF4D44A0) // plastic buttons on it
val Edge = Color(0xFF1A1540) // the shadow under plastic and paper
val Accent = Color(0xFFF7A531) // orange: the main thing to press
val AccentEdge = Color(0xFFB86F12)
val OnAccent = Color(0xFF3A2410)
val Good = Color(0xFF5DBB46) // leaf green: what's selected, the bag
val GoodEdge = Color(0xFF2F7A22)
val OnGood = Color(0xFF16300C)
val Bad = Color(0xFFF07167)
val TextMain = Color(0xFFF2EFFF) // on plastic
val TextDim = Color(0xFFC3BCF5)
val Paper = Color(0xFFFFF4D6) // speech bubbles, cards, sheets
val PaperDeep = Color(0xFFF0DFB4) // pockets, presents
val PaperEdge = Color(0xFFC9A86A)
val Ink = Color(0xFF4A3B2A) // on paper
val InkDim = Color(0xFF6E5A40)
val InkFaint = Color(0xFF8A7458)
val InkLink = Color(0xFFA35E00)

/** Rounded and friendly, for everything people read. */
val Rounded = FontFamily(
    Font(R.font.rounded_regular, FontWeight.Normal),
    Font(R.font.rounded_medium, FontWeight.Medium),
    Font(R.font.rounded_bold, FontWeight.Bold),
    Font(R.font.rounded_extrabold, FontWeight.ExtraBold),
)

/** Wide and techy, for small capital labels ("UNIVERSE 0,0 · 3 HERE"). */
val Tech = FontFamily(Font(R.font.tech))

private val scheme = darkColorScheme(
    primary = Accent,
    onPrimary = OnAccent,
    secondary = Good,
    onSecondary = OnGood,
    background = Night,
    onBackground = TextMain,
    surface = Panel,
    onSurface = TextMain,
    surfaceVariant = PanelHi,
    onSurfaceVariant = TextDim,
    surfaceContainer = Panel,
    surfaceContainerHigh = Panel,
    surfaceContainerHighest = PanelHi,
    outline = Color(0xFF8B82D8),
    error = Bad,
)

private val type = Typography().let { t ->
    fun TextStyle.r(w: FontWeight? = null) = copy(fontFamily = Rounded, fontWeight = w ?: fontWeight)
    Typography(
        displayLarge = t.displayLarge.r(FontWeight.ExtraBold),
        headlineMedium = t.headlineMedium.r(FontWeight.ExtraBold),
        titleLarge = t.titleLarge.r(FontWeight.ExtraBold),
        titleMedium = t.titleMedium.r(FontWeight.ExtraBold),
        titleSmall = t.titleSmall.r(FontWeight.Bold),
        bodyLarge = t.bodyLarge.r(FontWeight.Medium),
        bodyMedium = t.bodyMedium.r(FontWeight.Medium),
        bodySmall = t.bodySmall.r(),
        labelLarge = t.labelLarge.r(FontWeight.Bold),
        labelMedium = t.labelMedium.r(FontWeight.Bold),
        labelSmall = t.labelSmall.r(FontWeight.Bold),
    )
}

/** The small capital labels. */
val TechLabel = TextStyle(fontFamily = Tech, fontSize = 9.sp, letterSpacing = 1.4.sp)

@Composable
fun SoshTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = scheme, typography = type, content = content)
}

/** "RRGGBB" as a colour. */
fun hex(s: String?, fallback: Color = Color.White): Color = try {
    if (s == null || s.length != 6) fallback else Color(0xFF000000 or s.toLong(16))
} catch (e: NumberFormatException) {
    fallback
}

private val tags = listOf(0xFF9FE3D0, 0xFFFFD35C, 0xFFD9B8F5, 0xFFBFD7FF, 0xFFFFB8A8, 0xFFC8EB9A, 0xFFFFC6E0, 0xFFE6C9A8)

/** A steady pastel per handle: a name tag's colour (dark ink goes on it). */
fun handleColor(handle: String): Color = Color(tags[(handle.hashCode() and 0x7fffffff) % tags.size])

/** The same person's colour dark enough to read on paper. */
fun handleInk(handle: String): Color = lerp(handleColor(handle), Ink, 0.62f)

private fun lerp(a: Color, b: Color, t: Float) =
    Color(a.red + (b.red - a.red) * t, a.green + (b.green - a.green) * t, a.blue + (b.blue - a.blue) * t)
