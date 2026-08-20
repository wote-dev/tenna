package com.tennanova.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CornerBasedShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * A CSS `box-shadow`, which `Modifier.shadow` cannot express.
 *
 * `Modifier.shadow`'s ambientColor/spotColor are *tints*, multiplied by the framework's
 * own hard-wired ambient (~0.039) and spot (~0.19) alphas, so a translucent input all but
 * vanishes; reaching a 48px-blur look needs ~14dp elevation, by which point the shadow is
 * far too dark and too tight. `Paint.setShadowLayer` takes an explicit Gaussian radius,
 * offset and ARGB, which is exactly the CSS model.
 */
@Immutable
data class SoftShadow(
    val color: Color,
    val offsetY: Dp,
    val blurRadius: Dp,
    /** CSS `spread`, negated: how far in from the node's bounds the shadow rect sits. */
    val inset: Dp
)

/**
 * The glass vocabulary: surface, hairline and shadow tokens, held as plain colours rather
 * than an array so the class keeps value equality.
 */
@Immutable
data class GlassTokens(
    val backdropTop: Color,
    val backdropMid: Color,
    val backdropBottom: Color,
    val ribbon: Color,
    val panel: Color,
    val panelFlat: Color,
    val panelSunk: Color,
    val hairline: Color,
    val hairlineStrong: Color,
    val specular: Color,
    val accent: Color,
    val shadowSoft: SoftShadow,
    val shadowLift: SoftShadow
)

internal val TennaGlass = GlassTokens(
    backdropTop = Color(0xFFE0EAFC),
    backdropMid = Color(0xFFCFDEF3),
    backdropBottom = Color(0xFFE2D4F0),
    ribbon = Color(0x59FFFFFF),
    panel = Color(0x99FFFFFF),
    panelFlat = Color(0x80FFFFFF),
    panelSunk = Color(0x4DFFFFFF),
    hairline = Color(0x99FFFFFF),
    hairlineStrong = Color(0xCCFFFFFF),
    specular = Color(0x40FFFFFF),
    accent = Color(0xFF0EA5E9),
    // web --shadow-soft: 0 24px 48px -28px rgba(14,165,233,0.25).
    // CSS blur B is sigma = B/2; Skia's sigma = 0.57735r + 0.5, so r ~= 0.866B.
    shadowSoft = SoftShadow(Color(0x400EA5E9), offsetY = 24.dp, blurRadius = 40.dp, inset = 28.dp),
    // web --shadow-lift: 0 16px 32px -18px rgba(30,41,59,0.10).
    shadowLift = SoftShadow(Color(0x1A1E293B), offsetY = 16.dp, blurRadius = 28.dp, inset = 18.dp)
)

/** Static: these never change within the theme, so read-tracking would be pure overhead. */
val LocalGlass = staticCompositionLocalOf<GlassTokens> {
    error("GlassTokens not provided — wrap the content in TennaTheme")
}

/**
 * The page backdrop: the icon's gradient, plus the light ribbon blooming from the
 * top-left, which is the direction the panel shadows already imply.
 *
 * Drawn behind the Scaffold rather than as its container colour so it spans the system
 * bars and stays put while the content scrolls, matching the site's fixed attachment.
 */
@Composable
fun Modifier.tennaBackdrop(): Modifier {
    val g = LocalGlass.current
    return this.drawWithCache {
        val base = Brush.linearGradient(
            0f to g.backdropTop,
            0.5f to g.backdropMid,
            1f to g.backdropBottom,
            start = Offset.Zero,
            end = Offset(size.width, size.height)
        )
        val ribbon = Brush.radialGradient(
            colors = listOf(g.ribbon, Color.Transparent),
            center = Offset(size.width * 0.16f, size.height * 0.04f),
            radius = size.maxDimension * 0.62f
        )
        onDrawBehind {
            drawRect(base)
            drawRect(ribbon)
        }
    }
}

/**
 * Draws [shadow] outside the node's bounds, so it must come before `clip` in the chain.
 *
 * `drawWithCache` rather than `drawBehind` is not a micro-optimisation: the naive version
 * rebuilds the Paint's BlurMaskFilter every frame, which is plainly visible on a fling.
 */
fun Modifier.softShadow(shadow: SoftShadow, cornerRadius: Dp): Modifier =
    this.drawWithCache {
        val paint = Paint().apply {
            asFrameworkPaint().apply {
                color = android.graphics.Color.TRANSPARENT
                setShadowLayer(
                    shadow.blurRadius.toPx(),
                    0f,
                    shadow.offsetY.toPx(),
                    shadow.color.toArgb()
                )
            }
        }
        val radius = cornerRadius.toPx()
        // Clamped, or a short row turns a -28dp spread into a negative-height rect and
        // Skia silently draws nothing at all.
        val insetX = shadow.inset.toPx().coerceIn(0f, size.width / 2f - 1f)
        val insetY = shadow.inset.toPx().coerceIn(0f, size.height / 2f - 1f)
        onDrawBehind {
            drawIntoCanvas { canvas ->
                canvas.drawRoundRect(
                    insetX,
                    insetY,
                    size.width - insetX,
                    size.height - insetY,
                    radius,
                    radius,
                    paint
                )
            }
        }
    }

/** How much the panel floats: a full card, a list row, or an inset well. */
enum class GlassTone { Raised, Flat, Sunk }

/**
 * One pane of frosted glass.
 *
 * There is no backdrop blur here and that is deliberate. Compose's `Modifier.blur` blurs a
 * node's *own* content, not what is behind it, so real glassmorphism would need a library
 * capturing the backdrop into a layer every frame. It would buy nothing: a Gaussian blur
 * is a symmetric convolution and a linear ramp is invariant under one, so blurring this
 * backdrop — a three-stop gradient and one very low-frequency bloom — reproduces it
 * exactly. The frost comes from the translucent fill, the lit hairline edge and the soft
 * shadow acting together; drop any one and it reads as a flat white box.
 *
 * [cornerRadius] is passed alongside [shape] because `softShadow` needs a scalar radius in
 * pixels, and resolving that out of an arbitrary `CornerBasedShape` needs a Density and a
 * Size that are not available here.
 */
@Composable
fun GlassSurface(
    modifier: Modifier = Modifier,
    tone: GlassTone = GlassTone.Raised,
    shape: CornerBasedShape = MaterialTheme.shapes.large,
    cornerRadius: Dp = 24.dp,
    contentPadding: PaddingValues = PaddingValues(0.dp),
    verticalArrangement: Arrangement.Vertical = Arrangement.Top,
    onClick: (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit
) {
    val g = LocalGlass.current
    val fill = when (tone) {
        GlassTone.Raised -> g.panel
        GlassTone.Flat -> g.panelFlat
        GlassTone.Sunk -> g.panelSunk
    }
    val shadow = when (tone) {
        GlassTone.Raised -> g.shadowSoft
        GlassTone.Flat -> g.shadowLift
        GlassTone.Sunk -> null
    }

    var m = modifier
    if (shadow != null) m = m.softShadow(shadow, cornerRadius)
    m = m.clip(shape).background(fill)
    if (tone == GlassTone.Raised) {
        m = m.background(Brush.verticalGradient(0f to g.specular, 0.45f to Color.Transparent))
    }
    // After clip, so the ripple follows the rounded corners rather than squaring them off.
    if (onClick != null) m = m.clickable(onClick = onClick)
    // Last, so the lit edge stays crisp above the ripple.
    m = m.border(1.dp, g.hairline, shape)

    Column(
        modifier = m.padding(contentPadding),
        verticalArrangement = verticalArrangement,
        content = content
    )
}
