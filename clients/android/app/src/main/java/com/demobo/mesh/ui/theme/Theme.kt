package com.demobo.mesh.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.demobo.mesh.nodes.Tier

// Warm stone neutrals; colour is reserved for where text goes.
private val Light = lightColorScheme(
    primary = Color(0xFF1C1917), onPrimary = Color.White,
    primaryContainer = Color(0xFFEDEAE7), onPrimaryContainer = Color(0xFF1C1917),
    secondary = Color(0xFF0F766E), onSecondary = Color.White,
    secondaryContainer = Color(0xFFCCF0EA), onSecondaryContainer = Color(0xFF0B4F4A),
    tertiary = Color(0xFFB45309), onTertiary = Color.White,
    tertiaryContainer = Color(0xFFFDEBC8), onTertiaryContainer = Color(0xFF6B3206),
    background = Color(0xFFFAFAF9), onBackground = Color(0xFF1C1917),
    surface = Color(0xFFFAFAF9), onSurface = Color(0xFF1C1917),
    surfaceVariant = Color(0xFFF2F0EE), onSurfaceVariant = Color(0xFF57534E),
    surfaceContainerLowest = Color.White, surfaceContainerLow = Color(0xFFF7F6F5),
    surfaceContainer = Color(0xFFF2F0EE), surfaceContainerHigh = Color(0xFFECE9E6),
    surfaceContainerHighest = Color(0xFFE7E5E4),
    outline = Color(0xFFD6D3D1), outlineVariant = Color(0xFFE7E5E4),
    error = Color(0xFFB91C1C), onError = Color.White,
    errorContainer = Color(0xFFFDE2E2), onErrorContainer = Color(0xFF7F1D1D),
)

private val Dark = darkColorScheme(
    primary = Color(0xFFFAFAF9), onPrimary = Color(0xFF1C1917),
    primaryContainer = Color(0xFF2E2A27), onPrimaryContainer = Color(0xFFFAFAF9),
    secondary = Color(0xFF2DD4BF), onSecondary = Color(0xFF042F2C),
    secondaryContainer = Color(0xFF0D3B37), onSecondaryContainer = Color(0xFF99F0E2),
    tertiary = Color(0xFFFBBF24), onTertiary = Color(0xFF3A2201),
    tertiaryContainer = Color(0xFF4A2E07), onTertiaryContainer = Color(0xFFFDE3A8),
    background = Color(0xFF0C0A09), onBackground = Color(0xFFF5F5F4),
    surface = Color(0xFF0C0A09), onSurface = Color(0xFFF5F5F4),
    surfaceVariant = Color(0xFF1C1917), onSurfaceVariant = Color(0xFFA8A29E),
    surfaceContainerLowest = Color(0xFF0C0A09), surfaceContainerLow = Color(0xFF151311),
    surfaceContainer = Color(0xFF1C1917), surfaceContainerHigh = Color(0xFF292524),
    surfaceContainerHighest = Color(0xFF33302D),
    outline = Color(0xFF44403C), outlineVariant = Color(0xFF292524),
    error = Color(0xFFF87171), onError = Color(0xFF450A0A),
    errorContainer = Color(0xFF3B1212), onErrorContainer = Color(0xFFFECACA),
)

/** One colour per destination: the phone, the user's own mesh, the cloud. */
@Immutable
data class TierColors(val phone: Color, val mesh: Color, val cloud: Color, val off: Color) {
    fun of(tier: Tier): Color = when (tier) {
        Tier.T0 -> phone
        Tier.T4 -> cloud
        else -> mesh
    }

    fun of(tier: String): Color = Tier.of(tier)?.let { of(it) } ?: off
}

private val LightTiers = TierColors(phone = Color(0xFF0F766E), mesh = Color(0xFF2563EB), cloud = Color(0xFFB45309), off = Color(0xFFA8A29E))
private val DarkTiers = TierColors(phone = Color(0xFF2DD4BF), mesh = Color(0xFF60A5FA), cloud = Color(0xFFFBBF24), off = Color(0xFF57534E))

val LocalTierColors = staticCompositionLocalOf { LightTiers }

private val Type = Typography().run {
    copy(
        titleLarge = titleLarge.copy(fontWeight = FontWeight.SemiBold, fontSize = 20.sp, letterSpacing = 0.sp),
        titleMedium = titleMedium.copy(fontWeight = FontWeight.SemiBold),
        bodyLarge = TextStyle(fontSize = 16.sp, lineHeight = 25.sp, letterSpacing = 0.15.sp),
        bodyMedium = bodyMedium.copy(lineHeight = 21.sp),
        labelSmall = labelSmall.copy(fontSize = 11.5.sp, letterSpacing = 0.2.sp),
    )
}

private val MeshShapes = Shapes(
    extraSmall = RoundedCornerShape(6.dp),
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(16.dp),
    large = RoundedCornerShape(22.dp),
    extraLarge = RoundedCornerShape(28.dp),
)

@Composable
fun MeshTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    androidx.compose.runtime.CompositionLocalProvider(LocalTierColors provides if (dark) DarkTiers else LightTiers) {
        MaterialTheme(colorScheme = if (dark) Dark else Light, typography = Type, shapes = MeshShapes, content = content)
    }
}

object MeshTheme {
    val tiers: TierColors @Composable get() = LocalTierColors.current
}
