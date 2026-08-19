package com.tennanova.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.LinkOff
import androidx.compose.material.icons.outlined.Message
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material3.Switch
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.tennanova.R
import com.tennanova.clipboard.ClipboardAccessStatus
import com.tennanova.core.SmsAccessStatus
import com.tennanova.core.ConnectionStatus
import com.tennanova.net.ConnectionTransport

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun DashboardScreen(
    state: MainUiState,
    onOpenNotificationAccess: () -> Unit,
    onOpenAccessibility: () -> Unit,
    onScanQr: () -> Unit,
    onPair: (String) -> Boolean,
    onUnpair: () -> Unit,
    onSetSmsEnabled: (Boolean) -> Unit
) {
    // Saveable, not merely remembered: a rotation or a fold recreates the Activity, and
    // losing a half-typed pairing code to one is exactly the kind of glitch this screen
    // cannot afford at the only moment it matters.
    var showManualPair by rememberSaveable { mutableStateOf(false) }
    var showUnpair by rememberSaveable { mutableStateOf(false) }

    val notificationsReady = state.listenerEnabled
    val clipboardReady = state.clipboard == ClipboardAccessStatus.READY
    val everythingGranted = notificationsReady && clipboardReady

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        contentColor = MaterialTheme.colorScheme.onBackground,
        topBar = { DashboardTopBar() }
    ) { insets ->
        Column(
            modifier = Modifier.fillMaxSize().padding(insets)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp)
        ) {
            ConnectionHero(state)

            if (!state.paired) {
                PairingCard(onScanQr) { showManualPair = true }
            } else {
                PairedRow(state) { showUnpair = true }
            }

            if (!everythingGranted) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionTitle("Finish setup")
                    if (!notificationsReady) {
                        ServiceRow(
                            icon = Icons.Outlined.Notifications,
                            title = "Notification mirroring",
                            status = "Needs access",
                            detail = "Allow notification access so Tennanova can mirror alerts " +
                                "and replies.",
                            onAction = onOpenNotificationAccess
                        )
                    }
                    if (!clipboardReady) {
                        val (status, detail) = clipboardCopy(state)
                        ServiceRow(
                            icon = Icons.Outlined.ContentCopy,
                            title = "Universal clipboard",
                            status = status,
                            detail = detail,
                            onAction = onOpenAccessibility
                        )
                    }
                }
            }

            // Deliberately outside "Finish setup": SMS is a choice, not an unfinished
            // step, and the app is complete without it.
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SectionTitle("Messages")
                val (smsStatus, smsDetail) = smsCopy(state)
                FeatureToggleRow(
                    icon = Icons.Outlined.Message,
                    title = "Text messages",
                    status = smsStatus,
                    detail = smsDetail,
                    checked = state.sms != SmsAccessStatus.OFF,
                    onCheckedChange = onSetSmsEnabled
                )
            }

            AnimatedVisibility(
                state.error != null || state.message != null || state.lastTransfer != null
            ) {
                ActivityLine(state)
            }

            PrivacyNote()
            Spacer(Modifier.height(8.dp))
        }
    }

    if (showManualPair) ManualPairSheet(onDismiss = { showManualPair = false }) { value ->
        if (onPair(value)) showManualPair = false
    }
    if (showUnpair) UnpairDialog(
        onDismiss = { showUnpair = false },
        onConfirm = { showUnpair = false; onUnpair() }
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DashboardTopBar() {
    CenterAlignedTopAppBar(
        colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
            containerColor = MaterialTheme.colorScheme.background,
            scrolledContainerColor = MaterialTheme.colorScheme.background
        ),
        title = {
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Image(
                    painter = painterResource(R.drawable.tennanova_icon),
                    contentDescription = null,
                    modifier = Modifier.size(28.dp).clip(RoundedCornerShape(8.dp))
                )
                Text(
                    "Tennanova",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.SemiBold
                )
            }
        }
    )
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ConnectionHero(state: MainUiState) {
    val (title, detail) = connectionCopy(state)
    val accent = connectionAccent(state.connection)

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        StatusHeadline(title = title, accent = accent)
        Text(
            detail,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        if (state.connection == ConnectionStatus.CONNECTED) {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.padding(top = 4.dp)
            ) {
                CapabilityChip(
                    Icons.Outlined.Notifications, "Notifications", state.listenerEnabled
                )
                CapabilityChip(
                    Icons.Outlined.ContentCopy, "Text",
                    state.clipboard == ClipboardAccessStatus.READY
                )
                CapabilityChip(
                    Icons.Outlined.Image, "Images",
                    state.clipboard == ClipboardAccessStatus.READY && state.peerSupportsImages
                )
            }
        }
    }
}

/** Internal transport phases intentionally collapse to one calm, user-facing state. */
internal fun connectionCopy(state: MainUiState): Pair<String, String> {
    if (state.paired && !state.listenerEnabled) {
        return "Connection paused" to
            "Enable notification access so Android can run the Mac connection service."
    }
    if (state.paired && !state.connectionServiceRunning &&
        state.connection !in setOf(
            ConnectionStatus.CONNECTED,
            ConnectionStatus.AUTH_FAILED,
            ConnectionStatus.PIN_MISMATCH
        )) {
        return "Starting connection…" to
            "Waiting for Android to start the Tennanova connection service."
    }
    return when (state.connection) {
        // A relayed session works, but it leans on a server and it is slower than the
        // same two devices on one Wi-Fi. Saying "Connected" flat would hide the reason
        // sync feels different here, and hide that a blocked network is being worked
        // around rather than fixed.
        ConnectionStatus.CONNECTED -> when (state.transport) {
            ConnectionTransport.RELAY ->
                "Connected over the internet" to
                    "This network blocks device-to-device traffic, so Tennanova is " +
                        "relaying through your Mac's relay server."
            ConnectionTransport.USB ->
                "Connected by USB" to "Your phone and Mac are in sync over the cable."
            else ->
                "Connected" to "Your phone and Mac are in sync."
        }
        ConnectionStatus.CONNECTING,
        ConnectionStatus.AUTHENTICATING,
        ConnectionStatus.DISCONNECTED -> if (state.pairingConfirmed) {
            "Reconnecting…" to "Searching every shared network for your paired Mac."
        } else {
            "Finishing pairing…" to "Searching every shared network for your Mac."
        }
        ConnectionStatus.PIN_MISMATCH ->
            "Mac identity changed" to "Re-pair before syncing again."
        ConnectionStatus.AUTH_FAILED ->
            "Pairing rejected" to "Scan a fresh code from the Mac."
        ConnectionStatus.UNPAIRED ->
            "Pair your Mac" to "Connect once to sync notifications, text and images."
    }
}

@Composable
private fun connectionAccent(status: ConnectionStatus): Color = when (status) {
    ConnectionStatus.CONNECTED -> MaterialTheme.colorScheme.primary
    ConnectionStatus.CONNECTING,
    ConnectionStatus.AUTHENTICATING,
    ConnectionStatus.DISCONNECTED -> MaterialTheme.colorScheme.tertiary
    ConnectionStatus.PIN_MISMATCH,
    ConnectionStatus.AUTH_FAILED -> MaterialTheme.colorScheme.error
    ConnectionStatus.UNPAIRED -> MaterialTheme.colorScheme.onSurfaceVariant
}

@Composable
private fun CapabilityChip(icon: ImageVector, label: String, active: Boolean) {
    val colors = if (active) {
        AssistChipDefaults.assistChipColors(
            containerColor = MaterialTheme.colorScheme.secondaryContainer,
            labelColor = MaterialTheme.colorScheme.onSecondaryContainer,
            leadingIconContentColor = MaterialTheme.colorScheme.onSecondaryContainer
        )
    } else {
        AssistChipDefaults.assistChipColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
            labelColor = MaterialTheme.colorScheme.onSurfaceVariant,
            leadingIconContentColor = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
    AssistChip(
        onClick = {},
        label = { Text(label) },
        leadingIcon = {
            Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp))
        },
        colors = colors,
        border = AssistChipDefaults.assistChipBorder(
            enabled = true,
            borderColor = Color.Transparent
        )
    )
}

@Composable
private fun ActivityLine(state: MainUiState) {
    val isError = state.error != null
    val message = state.error ?: state.message ?: state.lastTransfer.orEmpty()
    Text(
        message,
        style = MaterialTheme.typography.bodyMedium,
        color = if (isError) MaterialTheme.colorScheme.error
            else MaterialTheme.colorScheme.onSurfaceVariant
    )
}

@Composable
private fun PairingCard(onScan: () -> Unit, onManual: () -> Unit) {
    OutlinedCard(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.outlinedCardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow
        ),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(
                "Connect your Mac",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                "Open Tennanova in the Mac menu bar, then scan its QR code.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Button(onClick = onScan, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Outlined.QrCodeScanner, null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(8.dp))
                Text("Scan pairing code")
            }
            TextButton(onClick = onManual, modifier = Modifier.fillMaxWidth()) {
                Text("Enter code manually")
            }
        }
    }
}

@Composable
private fun PairedRow(state: MainUiState, onUnpair: () -> Unit) {
    ListItem(
        headlineContent = {
            Text(
                if (state.pairingConfirmed) "Paired Mac" else "Pairing pending",
                fontWeight = FontWeight.Medium
            )
        },
        supportingContent = {
            Text(
                state.macName ?: state.host.orEmpty(),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        },
        leadingContent = {
            Icon(
                Icons.Outlined.Devices,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary
            )
        },
        trailingContent = {
            TextButton(onClick = onUnpair) {
                Text("Unpair")
            }
        },
        colors = ListItemDefaults.colors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow
        ),
        modifier = Modifier.clip(RoundedCornerShape(16.dp))
    )
}

@Composable
private fun ServiceRow(
    icon: ImageVector,
    title: String,
    status: String,
    detail: String,
    onAction: () -> Unit
) {
    val statusColor = if (status == "Needs attention") MaterialTheme.colorScheme.error
        else MaterialTheme.colorScheme.onSurfaceVariant
    Column {
        ListItem(
            headlineContent = { Text(title, fontWeight = FontWeight.Medium) },
            overlineContent = { Text(status, color = statusColor) },
            supportingContent = { Text(detail) },
            leadingContent = {
                Icon(icon, contentDescription = null, tint = statusColor)
            },
            trailingContent = {
                TextButton(onClick = onAction) { Text("Enable") }
            },
            colors = ListItemDefaults.colors(
                containerColor = MaterialTheme.colorScheme.surfaceContainerLow
            ),
            modifier = Modifier.clip(RoundedCornerShape(16.dp))
        )
    }
}

@Composable
private fun PrivacyNote() {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        Text(
            "Tennanova talks straight to your Mac over your local network or its USB " +
                "tunnel. Nothing is uploaded to a cloud service.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

/**
 * A feature the user opts into, rather than a permission they must grant to finish setup.
 * The switch, not an "Enable" button, is what says it can be turned back off.
 */
@Composable
private fun FeatureToggleRow(
    icon: ImageVector,
    title: String,
    status: String,
    detail: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit
) {
    val statusColor = if (status == "Needs attention") MaterialTheme.colorScheme.error
        else MaterialTheme.colorScheme.onSurfaceVariant
    ListItem(
        headlineContent = { Text(title, fontWeight = FontWeight.Medium) },
        overlineContent = { Text(status, color = statusColor) },
        supportingContent = { Text(detail) },
        leadingContent = { Icon(icon, contentDescription = null, tint = statusColor) },
        trailingContent = {
            Switch(checked = checked, onCheckedChange = onCheckedChange)
        },
        colors = ListItemDefaults.colors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow
        ),
        modifier = Modifier.clip(RoundedCornerShape(16.dp))
    )
}

internal fun smsCopy(state: MainUiState): Pair<String, String> = when (state.sms) {
    SmsAccessStatus.OFF -> "Off" to
        "Turn this on to read and send your texts from your Mac. Real conversations with " +
        "their history, not just notifications."
    SmsAccessStatus.NEEDS_PERMISSION -> "Needs access" to
        "Allow Tennanova to read and send SMS, and to see your contacts so names travel " +
        "with the numbers."
    SmsAccessStatus.READY -> "On" to if (state.smsThreadCount > 0)
        "${state.smsThreadCount} conversations are on your Mac. Text messages only — " +
        "picture messages stay on the phone."
    else "Your texts will appear on your Mac. Text messages only — picture messages " +
        "stay on the phone."
    SmsAccessStatus.ERROR -> "Needs attention" to
        "Tennanova could not read this phone's messages. Check its permissions in Settings."
}

internal fun clipboardCopy(state: MainUiState): Pair<String, String> = when (state.clipboard) {
    ClipboardAccessStatus.READY -> "Ready" to if (state.peerSupportsImages)
        "Text and single images sync in both directions while your Mac is connected."
    else "Text sync is ready. Update the Mac app to enable image sync."
    ClipboardAccessStatus.NEEDS_ACCESSIBILITY -> "Needs access" to
        "Enable Tennanova clipboard sync once in Accessibility settings. No Shizuku or reboot setup is needed."
    ClipboardAccessStatus.ERROR -> "Needs attention" to
        (state.clipboardError ?: "Clipboard capture failed. Review Accessibility access and try copying again.")
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ManualPairSheet(onDismiss: () -> Unit, onPair: (String) -> Unit) {
    var value by rememberSaveable { mutableStateOf("") }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        // A half-height sheet re-settles when the keyboard resizes it, and one of the
        // positions it can settle into is `Hidden` — which dismisses the sheet mid-typing.
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        containerColor = MaterialTheme.colorScheme.surfaceContainer
    ) {
        Column(
            // `enableEdgeToEdge` stops the framework applying IME insets, so without this the
            // four-line field sits under the keyboard the moment it opens.
            Modifier.imePadding().padding(horizontal = 20.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Text(
                "Enter pairing code",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                "Paste the code copied from the Tennanova Mac menu.",
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            OutlinedTextField(
                value = value,
                onValueChange = { value = it },
                label = { Text("Pairing code") },
                minLines = 4,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth()
            )
            Button(
                onClick = { onPair(value) },
                enabled = value.isNotBlank(),
                modifier = Modifier.fillMaxWidth()
            ) { Text("Pair securely") }
        }
    }
}

@Composable
private fun UnpairDialog(onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = {
            Icon(
                Icons.Outlined.LinkOff,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.error
            )
        },
        title = { Text("Unpair this Mac?") },
        text = { Text("Notification and clipboard syncing will stop until you pair again.") },
        confirmButton = {
            TextButton(
                onClick = onConfirm,
                colors = ButtonDefaults.textButtonColors(
                    contentColor = MaterialTheme.colorScheme.error
                )
            ) { Text("Unpair") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
        shape = RoundedCornerShape(28.dp),
        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh
    )
}
