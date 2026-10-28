package app.sosh.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// The game's own palette (client/scripts/ui.lua): night panels, warm text,
// an amber accent.
val Night = Color(0xFF141A26)
val Panel = Color(0xFF1C2433)
val PanelHi = Color(0xFF26304A)
val Accent = Color(0xFFF2B84B)
val Good = Color(0xFF7BD389)
val Bad = Color(0xFFF07167)
val TextMain = Color(0xFFF4F0E6)
val TextDim = Color(0xFFA8B0BC)

private val scheme = darkColorScheme(
    primary = Accent,
    onPrimary = Night,
    secondary = Good,
    background = Night,
    onBackground = TextMain,
    surface = Panel,
    onSurface = TextMain,
    surfaceVariant = PanelHi,
    onSurfaceVariant = TextDim,
    error = Bad,
)

@Composable
fun SoshTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = scheme, content = content)
}

/** "RRGGBB" as a colour. */
fun hex(s: String?, fallback: Color = Color.White): Color = try {
    if (s == null || s.length != 6) fallback else Color(0xFF000000 or s.toLong(16))
} catch (e: NumberFormatException) {
    fallback
}

/** A steady colour per handle, like the game's name colours. */
fun handleColor(handle: String): Color {
    val palette = listOf(0xFFF28B82, 0xFFFBBC04, 0xFFCCFF90, 0xFFA7FFEB, 0xFFAECBFA, 0xFFD7AEFB, 0xFFFDCFE8, 0xFFE6C9A8)
    return Color(palette[(handle.hashCode() and 0x7fffffff) % palette.size])
}
