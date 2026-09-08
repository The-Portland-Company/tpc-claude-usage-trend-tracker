package com.theportlandcompany.claudemeter.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// Severity colors — must match the parity manifest §5 exactly across platforms.
val SeverityNormalLight = Color(0xFFD97757) // accent (Claude orange-brown), used only as the accent color
val SeverityWarning = Color(0xFFFF9500)
val SeverityCritical = Color(0xFFFF3B30)

private val LightColors = lightColorScheme(primary = SeverityNormalLight)
private val DarkColors = darkColorScheme(primary = SeverityNormalLight)

@Composable
fun ClaudeMeterTheme(content: @Composable () -> Unit) {
    val colors = if (isSystemInDarkTheme()) DarkColors else LightColors
    MaterialTheme(colorScheme = colors, content = content)
}
