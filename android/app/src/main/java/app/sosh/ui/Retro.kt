package app.sosh.ui

import android.graphics.RenderEffect
import android.graphics.RuntimeShader
import android.os.Build
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.asComposeRenderEffect
import androidx.compose.ui.graphics.graphicsLayer
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * How the screen is drawn. Clean is the phone's own resolution; the others
 * redraw everything at a console's: `lines` pixels across the screen's short
 * side (rounded to whole device pixels a cell, so they stay even), scaled
 * back up with a soft filter as a TV would, and `levels` steps of each colour
 * (0 for all of them) with an ordered dither between.
 */
enum class Look(val label: String, val lines: Int, val levels: Float) {
    Clean("clean", 0, 0f),
    // an early-2000s console: 480 lines, smooth
    Sharp("480", 480, 0f),
    // the decade before: 320 lines, 15-bit colour dithered
    Soft("320", 320, 31f),
}

// Downsample to cells (four taps a cell, so thin strokes don't vanish), then
// filter back up between the four nearest cells.
private const val SHADER = """
uniform shader content;
uniform float2 size;
uniform float cell;
uniform float levels;

half4 cellAt(float2 c) {
    float2 o = c * cell;
    float2 lo = float2(0.5);
    float2 hi = size - 0.5;
    half4 sum = content.eval(clamp(o + float2(0.25, 0.25) * cell, lo, hi));
    sum += content.eval(clamp(o + float2(0.75, 0.25) * cell, lo, hi));
    sum += content.eval(clamp(o + float2(0.25, 0.75) * cell, lo, hi));
    sum += content.eval(clamp(o + float2(0.75, 0.75) * cell, lo, hi));
    return sum * 0.25;
}

half4 quantize(half4 col, float2 c) {
    if (levels <= 0.0) {
        return col;
    }
    // a 4x4 Bayer matrix, from two 2x2 ones
    float2 a = mod(c, 2.0);
    float2 b = mod(floor(c / 2.0), 2.0);
    float v = 4.0 * (abs(a.x - a.y) * 2.0 + a.y) + abs(b.x - b.y) * 2.0 + b.y;
    float d = (v + 0.5) / 16.0;
    return half4(floor(col.rgb * levels + d) / levels, col.a);
}

half4 main(float2 xy) {
    float2 g = xy / cell - 0.5;
    float2 i = floor(g);
    float2 f = g - i;
    half4 top = mix(quantize(cellAt(i), i), quantize(cellAt(i + float2(1, 0)), i + float2(1, 0)), f.x);
    half4 bottom = mix(quantize(cellAt(i + float2(0, 1)), i + float2(0, 1)), quantize(cellAt(i + 1.0), i + 1.0), f.x);
    return mix(top, bottom, f.y);
}
"""

/**
 * Draw this (and everything in it) in `look`. Needs Android 13's runtime
 * shaders; older phones stay clean.
 */
fun Modifier.retro(look: Look): Modifier =
    if (look == Look.Clean || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) this
    else composed {
        val shader = remember { RuntimeShader(SHADER) }
        graphicsLayer {
            val w = size.width
            val h = size.height
            if (w > 0f && h > 0f) {
                val cell = max(1, (minOf(w, h) / look.lines).roundToInt()).toFloat()
                shader.setFloatUniform("size", w, h)
                shader.setFloatUniform("cell", cell)
                shader.setFloatUniform("levels", look.levels)
                renderEffect = RenderEffect.createRuntimeShaderEffect(shader, "content").asComposeRenderEffect()
            }
        }
    }
