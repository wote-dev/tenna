package com.tennanova.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * Small live-status mark, matching the Mac menu bar. The halo is what keeps it reading as
 * a lit mark rather than a printed dot once it sits on glass.
 */
@Composable
internal fun StatusDot(color: Color, modifier: Modifier = Modifier) {
    Box(modifier = modifier.size(18.dp), contentAlignment = Alignment.Center) {
        Box(
            Modifier.size(18.dp)
                .clip(CircleShape)
                .background(color.copy(alpha = 0.18f))
        )
        Box(
            Modifier.size(8.dp)
                .clip(CircleShape)
                .background(color)
        )
    }
}

@Composable
internal fun SectionTitle(title: String, modifier: Modifier = Modifier) {
    Text(
        title,
        style = MaterialTheme.typography.titleSmall,
        fontWeight = FontWeight.Medium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier.fillMaxWidth().padding(horizontal = 4.dp)
    )
}

@Composable
internal fun StatusHeadline(
    title: String,
    accent: Color,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        StatusDot(accent)
        Text(
            title,
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.SemiBold
        )
    }
}
