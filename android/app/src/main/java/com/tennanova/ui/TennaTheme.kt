package com.tennanova.ui

import android.app.Activity
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.ripple.RippleAlpha
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LocalRippleConfiguration
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RippleConfiguration
import androidx.compose.material3.Shapes
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat

/**
 * Soft light aero: pale cyan-to-lavender gradient, frosted white panels, hairline edges.
 * Seeded from the app icon and kept in step with `web/styles.css`, which already speaks
 * this language — the two should read as one product.
 *
 * Light only. The glass effect is carried by white at 30-60% over a pale gradient, and
 * there is no honest dark inversion of that which still looks like the icon. See the
 * plan's parked "deep aero" palette if a night scheme is ever wanted back.
 *
 * On the two blues: the brand cyan `#0EA5E9` carries white at only 2.77:1 and `#0284C7`
 * at 4.10:1 — both fail AA for a 14sp button label. `primary` is therefore `#0273B0`
 * (5.15:1), the brightest sky in that family that carries white body text, and `#0EA5E9`
 * survives as `GlassTokens.accent` for the roles where contrast rules do not apply:
 * shadow tint, ripple, specular bloom.
 */
private val LightColors = lightColorScheme(
    primary = Color(0xFF0273B0),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFE0F2FE),
    onPrimaryContainer = Color(0xFF075985),
    inversePrimary = Color(0xFF7DD3FC),

    secondary = Color(0xFF475569),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFE2E8F0),
    onSecondaryContainer = Color(0xFF334155),

    // The gradient's lavender end, not another blue: primary and tertiary both drive
    // status dots, and two sky-blues make that dot carry no information at all.
    tertiary = Color(0xFF7C3AED),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFEDE9FE),
    onTertiaryContainer = Color(0xFF5B21B6),

    error = Color(0xFFBA1A1A),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF410002),

    background = Color(0xFFE0EAFC),
    onBackground = Color(0xFF1E293B),

    // Deliberately the *effective* colour of a 60%-white panel over the gradient, so any
    // component that falls back to `surface` lands where the glass already is.
    surface = Color(0xFFEDF3FA),
    onSurface = Color(0xFF1E293B),
    surfaceVariant = Color(0xFFDCE4EE),
    // #64748B (the web's --ink-faint) is 3.54:1 over the darkest gradient stop and
    // 4.27:1 over a 60%-white panel. Both fail AA, so supporting copy uses --ink-dim.
    onSurfaceVariant = Color(0xFF475569),
    surfaceTint = Color(0xFF0273B0),

    outline = Color(0xFF64748B),
    outlineVariant = Color(0xFFCBD5E1),

    inverseSurface = Color(0xFF1E293B),
    inverseOnSurface = Color(0xFFF1F5F9),
    scrim = Color(0xFF1E293B),

    surfaceBright = Color(0xFFFFFFFF),
    surfaceDim = Color(0xFFD9E2F0),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFF7FAFD),
    surfaceContainer = Color(0xFFF1F6FB),
    surfaceContainerHigh = Color(0xFFEAF1F9),
    surfaceContainerHighest = Color(0xFFE3EBF5)
)

/**
 * 16dp and 24dp mirror the web's `--radius-sm` / `--radius`. Filled `Button` is
 * unaffected — its token maps to `CircleShape`, not to this — so buttons stay pills,
 * which is what `styles.css` draws too.
 */
private val TennaShapes = Shapes(
    extraSmall = RoundedCornerShape(12.dp),
    small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(16.dp),
    large = RoundedCornerShape(24.dp),
    extraLarge = RoundedCornerShape(28.dp)
)

/**
 * The default ripple derives from `contentColor` — slate at ~12% — which over white glass
 * reads as a grey thumbprint rather than a highlight.
 */
@OptIn(ExperimentalMaterial3Api::class)
private val TennaRipple = RippleConfiguration(
    color = Color(0xFF0EA5E9),
    rippleAlpha = RippleAlpha(
        draggedAlpha = 0.10f,
        focusedAlpha = 0.10f,
        hoveredAlpha = 0.06f,
        pressedAlpha = 0.10f
    )
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TennaTheme(content: @Composable () -> Unit) {
    val view = LocalView.current
    if (!view.isInEditMode) {
        val window = (view.context as? Activity)?.window
        // In a SideEffect, not the composition body: mutating the insets controller while
        // composing races enableEdgeToEdge's own pass on configuration change.
        SideEffect {
            window?.let {
                WindowCompat.getInsetsController(it, view).apply {
                    // Dark icons: every gradient stop is well above 0.7 luminance.
                    isAppearanceLightStatusBars = true
                    isAppearanceLightNavigationBars = true
                }
            }
        }
    }
    MaterialTheme(colorScheme = LightColors, shapes = TennaShapes) {
        CompositionLocalProvider(
            LocalGlass provides TennaGlass,
            LocalRippleConfiguration provides TennaRipple,
            content = content
        )
    }
}
