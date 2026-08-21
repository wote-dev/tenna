package com.tennanova.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Call
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.LinkOff
import androidx.compose.material.icons.outlined.Message
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material.icons.outlined.UploadFile
import androidx.compose.material3.Switch
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SwitchDefaults
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.tennanova.R
import com.tennanova.clipboard.ClipboardAccessStatus
import com.tennanova.core.CallAccessStatus
import com.tennanova.core.SmsAccessStatus
import com.tennanova.core.ConnectionStatus
import com.tennanova.files.TransferDirection
import com.tennanova.files.TransferItem
import com.tennanova.files.TransferState
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
    onSetSmsEnabled: (Boolean) -> Unit,
    onSetCallsEnabled: (Boolean) -> Unit,
    onGrantCallControl: () -> Unit,
    onCancelTransfer: (String) -> Unit = {},
    onClearTransfers: () -> Unit = {}
) {
    // Saveable, not merely remembered: a rotation or a fold recreates the Activity, and
    // losing a half-typed pairing code to one is exactly the kind of glitch this screen
    // cannot afford at the only moment it matters.
    var showManualPair by rememberSaveable { mutableStateOf(false) }
    var showUnpair by rememberSaveable { mutableStateOf(false) }

    val notificationsReady = state.listenerEnabled
    val clipboardReady = state.clipboard == ClipboardAccessStatus.READY
    val everythingGranted = notificationsReady && clipboardReady

    // The backdrop sits outside the Scaffold so it spans the system bars and stays put
    // while the content scrolls, the way the site's fixed background attachment does.
    Box(Modifier.fillMaxSize().tennaBackdrop()) {
        Scaffold(
            containerColor = Color.Transparent,
            contentColor = MaterialTheme.colorScheme.onBackground,
            topBar = { DashboardTopBar() }
        ) { insets ->
            Column(
                modifier = Modifier.fillMaxSize().padding(insets)
                    .verticalScroll(rememberScrollState())
                    // Asymmetric: verticalScroll clips to its bounds, so the panels need
                    // room for their 24dp-offset shadows at both ends.
                    .padding(horizontal = 20.dp)
                    .padding(top = 4.dp, bottom = 8.dp),
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

                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionTitle("Calls")
                    val (callStatus, callDetail) = callsCopy(state)
                    FeatureToggleRow(
                        icon = Icons.Outlined.Call,
                        title = "Calls on your Mac",
                        status = callStatus,
                        detail = callDetail,
                        checked = state.calls != CallAccessStatus.OFF,
                        onCheckedChange = onSetCallsEnabled,
                        // Only while it would change something. The feature is already
                        // working at this point, so this is an upgrade, not a fix.
                        action = "Allow call access".takeIf {
                            state.calls == CallAccessStatus.LIMITED
                        },
                        onAction = onGrantCallControl
                    )
                }

                // Only once there is something to say. An empty Files section on a phone
                // that has never moved one is a permanent reminder of a feature doing
                // nothing — the same rule the Calls row on the Mac follows.
                if (state.transfers.isNotEmpty() || state.peerSupportsFiles) {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            SectionTitle("Files")
                            Spacer(Modifier.weight(1f))
                            if (state.transfers.any { it.state.isFinished }) {
                                TextButton(onClick = onClearTransfers) { Text("Clear") }
                            }
                        }
                        FilesCard(state, onCancelTransfer)
                    }
                }

                AnimatedVisibility(
                    state.error != null || state.message != null || state.lastTransfer != null
                ) {
                    ActivityLine(state)
                }

                PrivacyNote()
                Spacer(Modifier.height(24.dp))
            }
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
        // Both transparent, so the backdrop runs behind the bar. scrolledContainerColor
        // matters even with no scrollBehavior attached: it is what a later one would fade
        // to, and a surface colour left there would punch a flat rectangle through.
        colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
            containerColor = Color.Transparent,
            scrolledContainerColor = Color.Transparent,
            titleContentColor = MaterialTheme.colorScheme.onBackground
        ),
        title = {
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Image(
                    painter = painterResource(R.drawable.tennanova_icon),
                    contentDescription = null,
                    // Lit edge, so the mark reads as a glass tile like the icon itself.
                    modifier = Modifier.size(28.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .border(1.dp, LocalGlass.current.hairlineStrong, RoundedCornerShape(10.dp))
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

    GlassSurface(
        modifier = Modifier.fillMaxWidth(),
        tone = GlassTone.Raised,
        cornerRadius = 24.dp,
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
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
                CapabilityChip(
                    Icons.Outlined.Call, "Calls", state.calls != CallAccessStatus.OFF
                )
                CapabilityChip(
                    Icons.Outlined.FolderOpen, "Files", state.peerSupportsFiles
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

/**
 * A plain Row rather than an `AssistChip`: the chip's container height is a hard 32dp that
 * clips its own label at large font scales, and these are read-only status markers that
 * were never clickable anyway. The padding matches `.spec-chips li` on the site.
 *
 * Sunk, with no shadow — a 40dp blur under a 32dp pill is a smudge, not a shadow.
 */
@Composable
private fun CapabilityChip(icon: ImageVector, label: String, active: Boolean) {
    val glass = LocalGlass.current
    val tint = if (active) MaterialTheme.colorScheme.onPrimaryContainer
        else MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(if (active) Color(0xCCE0F2FE) else glass.panelSunk)
            .border(
                1.dp,
                if (active) glass.hairlineStrong else glass.hairline,
                CircleShape
            )
            .padding(horizontal = 12.dp, vertical = 7.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp), tint = tint)
        Text(label, style = MaterialTheme.typography.labelLarge, color = tint)
    }
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
    GlassSurface(
        modifier = Modifier.fillMaxWidth(),
        tone = GlassTone.Raised,
        cornerRadius = 24.dp,
        contentPadding = PaddingValues(20.dp),
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

@Composable
private fun PairedRow(state: MainUiState, onUnpair: () -> Unit) {
    GlassSurface(
        modifier = Modifier.fillMaxWidth(),
        tone = GlassTone.Flat,
        shape = MaterialTheme.shapes.medium,
        cornerRadius = 16.dp
    ) {
        // ListItem is a Surface and paints its container edge to edge, so it has to be
        // transparent or it hides the glass underneath it.
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
                containerColor = Color.Transparent,
                headlineColor = MaterialTheme.colorScheme.onSurface,
                supportingColor = MaterialTheme.colorScheme.onSurfaceVariant,
                overlineColor = MaterialTheme.colorScheme.onSurfaceVariant
            )
        )
    }
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
    GlassSurface(
        modifier = Modifier.fillMaxWidth(),
        tone = GlassTone.Flat,
        shape = MaterialTheme.shapes.medium,
        cornerRadius = 16.dp
    ) {
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
                containerColor = Color.Transparent,
                headlineColor = MaterialTheme.colorScheme.onSurface,
                supportingColor = MaterialTheme.colorScheme.onSurfaceVariant,
                overlineColor = MaterialTheme.colorScheme.onSurfaceVariant
            )
        )
    }
}

@Composable
private fun PrivacyNote() {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        HorizontalDivider(color = LocalGlass.current.hairlineStrong, thickness = 1.dp)
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
    onCheckedChange: (Boolean) -> Unit,
    /** An optional extra grant this feature can use but does not need. */
    action: String? = null,
    onAction: () -> Unit = {}
) {
    val statusColor = if (status == "Needs attention") MaterialTheme.colorScheme.error
        else MaterialTheme.colorScheme.onSurfaceVariant
    GlassSurface(
        modifier = Modifier.fillMaxWidth(),
        tone = GlassTone.Flat,
        shape = MaterialTheme.shapes.medium,
        cornerRadius = 16.dp
    ) {
        ListItem(
            headlineContent = { Text(title, fontWeight = FontWeight.Medium) },
            overlineContent = { Text(status, color = statusColor) },
            supportingContent = {
                Column {
                    Text(detail)
                    // Inside the supporting slot rather than as a trailing button: the
                    // trailing slot is the switch, and this is a smaller, optional thing
                    // than the switch beside it.
                    if (action != null) {
                        TextButton(
                            onClick = onAction,
                            contentPadding = PaddingValues(horizontal = 0.dp, vertical = 4.dp)
                        ) { Text(action) }
                    }
                }
            },
            leadingContent = { Icon(icon, contentDescription = null, tint = statusColor) },
            trailingContent = {
                Switch(
                    checked = checked,
                    onCheckedChange = onCheckedChange,
                    // The default unchecked track is opaque, which reads as a solid chip
                    // sitting on an otherwise translucent row.
                    colors = SwitchDefaults.colors(
                        uncheckedTrackColor = Color(0x66FFFFFF),
                        uncheckedBorderColor = LocalGlass.current.hairlineStrong
                    )
                )
            },
            colors = ListItemDefaults.colors(
                containerColor = Color.Transparent,
                headlineColor = MaterialTheme.colorScheme.onSurface,
                supportingColor = MaterialTheme.colorScheme.onSurfaceVariant,
                overlineColor = MaterialTheme.colorScheme.onSurfaceVariant
            )
        )
    }
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

/**
 * Three states, and the middle one is the point.
 *
 * Calls reach the Mac with no permission at all — they are read out of notifications the
 * listener already receives — and most dialers put answer and decline intents in the
 * notification, so `LIMITED` is a feature that genuinely works. What it cannot do is
 * answer a call whose dialer offers no buttons, and only the optional call grant fixes
 * that. Calling it "needs access" would nag about something already doing its job.
 */
internal fun callsCopy(state: MainUiState): Pair<String, String> = when (state.calls) {
    CallAccessStatus.OFF -> "Off" to
        "Turn this on to see who is calling on your Mac and pick up from there. Phone " +
        "calls and app calls like WhatsApp and Signal both."
    CallAccessStatus.LIMITED -> "On" to
        "Calls appear on your Mac with your dialer's own Answer and Decline buttons. " +
        "Allow call access as well and Tennanova can answer even the dialers that offer " +
        "none. Either way the audio stays on this phone."
    CallAccessStatus.READY -> "On" to
        "Calls ring on your Mac, and answering, declining and hanging up all work from " +
        "there. The audio stays on this phone — Android lets no app carry it away."
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
        // A sheet is its own window over a dim, so a translucent container would composite
        // against the scrim rather than the app's backdrop and come out a dead grey slab.
        // It gets its own small gradient instead, and its own handle inside that gradient.
        containerColor = Color.Transparent,
        contentColor = MaterialTheme.colorScheme.onSurface,
        scrimColor = MaterialTheme.colorScheme.scrim.copy(alpha = 0.32f),
        dragHandle = null
    ) {
        Column(
            // `enableEdgeToEdge` stops the framework applying IME insets, so without this the
            // four-line field sits under the keyboard the moment it opens.
            Modifier.fillMaxWidth()
                .background(
                    Brush.verticalGradient(listOf(Color(0xFFF4F8FD), Color(0xFFE6EEF9))),
                    RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
                )
                .imePadding()
                .padding(horizontal = 20.dp)
                .padding(top = 12.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Spacer(
                Modifier.align(Alignment.CenterHorizontally)
                    .size(width = 36.dp, height = 4.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.outline.copy(alpha = 0.4f))
            )
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
                // Glassy, so the field does not punch a flat hole in the sheet. The shape
                // now comes from TennaShapes.extraSmall, which is the same 12dp.
                colors = OutlinedTextFieldDefaults.colors(
                    unfocusedContainerColor = Color(0x99FFFFFF),
                    focusedContainerColor = Color(0xCCFFFFFF),
                    unfocusedBorderColor = LocalGlass.current.hairlineStrong,
                    focusedBorderColor = MaterialTheme.colorScheme.primary
                ),
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
        // Also its own window, so the aero read has to come from the lit edge alone.
        modifier = Modifier.border(
            1.dp,
            LocalGlass.current.hairlineStrong,
            MaterialTheme.shapes.extraLarge
        ),
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
        containerColor = Color(0xFFF4F8FD)
    )
}


/**
 * The transfer list: one row per file, each saying which way it is going, how far it has
 * got, and what became of it.
 */
@Composable
private fun FilesCard(state: MainUiState, onCancel: (String) -> Unit) {
    GlassSurface(
        tone = GlassTone.Flat,
        shape = MaterialTheme.shapes.medium,
        cornerRadius = 16.dp,
        contentPadding = PaddingValues(vertical = 4.dp)
    ) {
        if (state.transfers.isEmpty()) {
            val (title, detail) = filesCopy(state)
            ListItem(
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                leadingContent = {
                    Icon(Icons.Outlined.FolderOpen, contentDescription = null)
                },
                headlineContent = { Text(title) },
                supportingContent = { Text(detail) }
            )
        } else {
            state.transfers.forEachIndexed { index, item ->
                TransferRow(item, onCancel)
                if (index != state.transfers.lastIndex) {
                    HorizontalDivider(Modifier.padding(horizontal = 16.dp))
                }
            }
        }
    }
}

@Composable
private fun TransferRow(item: TransferItem, onCancel: (String) -> Unit) {
    val outgoing = item.direction == TransferDirection.TO_MAC
    ListItem(
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        leadingContent = {
            Icon(
                if (outgoing) Icons.Outlined.UploadFile else Icons.Outlined.Download,
                contentDescription = if (outgoing) "Sending" else "Receiving",
                tint = when (item.state) {
                    TransferState.FAILED, TransferState.CANCELLED ->
                        MaterialTheme.colorScheme.error
                    TransferState.COMPLETED -> MaterialTheme.colorScheme.primary
                    else -> MaterialTheme.colorScheme.onSurfaceVariant
                }
            )
        },
        headlineContent = { Text(item.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(transferStatusLine(item))
                if (!item.state.isFinished) {
                    LinearProgressIndicator(
                        progress = { item.fraction },
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }
        },
        trailingContent = {
            if (!item.state.isFinished) {
                TextButton(onClick = { onCancel(item.id) }) { Text("Stop") }
            }
        }
    )
}

/**
 * One line per row. Pure and `internal` so it can be asserted on without Compose, the same
 * arrangement `smsCopy` and `callsCopy` use.
 */
internal fun transferStatusLine(item: TransferItem): String = when (item.state) {
    TransferState.QUEUED -> "Waiting its turn"
    TransferState.PREPARING -> "Preparing…"
    TransferState.OFFERED -> "Waiting for the Mac"
    TransferState.ACTIVE ->
        "${formatBytes(item.transferred)} of ${formatBytes(item.bytes)} · " +
            "${(item.fraction * 100).toInt()}%"
    TransferState.PAUSED -> item.detail ?: "Paused — it will continue when you reconnect"
    TransferState.VERIFYING -> "Checking it arrived intact…"
    TransferState.COMPLETED ->
        if (item.direction == TransferDirection.TO_MAC) "Sent · ${formatBytes(item.bytes)}"
        else item.detail ?: "Saved to Downloads"
    TransferState.CANCELLED -> "Cancelled"
    TransferState.FAILED -> item.detail ?: "Failed"
}

internal fun filesCopy(state: MainUiState): Pair<String, String> = when {
    !state.peerSupportsFiles ->
        "Files" to "Update the Mac app to send and receive files."
    else ->
        "Files" to "Share anything to Tennanova to send it to your Mac. " +
            "Files from the Mac land in Downloads."
}

/** Sizes as a person would say them, and never more precision than the number deserves. */
internal fun formatBytes(bytes: Long): String = when {
    bytes >= 1_000_000_000 -> "%.1f GB".format(bytes / 1_000_000_000.0)
    bytes >= 1_000_000 -> "%.1f MB".format(bytes / 1_000_000.0)
    bytes >= 1_000 -> "%.1f KB".format(bytes / 1_000.0)
    else -> "$bytes B"
}

/**
 * What the user meant by sharing an image.
 *
 * A screenshot shared to paste on the Mac and a photo shared to keep there are the same
 * gesture, and this app has done the first since before it could do the second. Guessing
 * either way silently removes one of them.
 */
@Composable
internal fun SharedImageChoice(
    onClipboard: () -> Unit,
    onFile: () -> Unit,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Send this image how?") },
        text = {
            Text(
                "Copying puts it on the Mac's clipboard, ready to paste. " +
                    "Sending saves it to the Mac's Downloads folder."
            )
        },
        confirmButton = { TextButton(onClick = onFile) { Text("Send as a file") } },
        dismissButton = { TextButton(onClick = onClipboard) { Text("Copy to clipboard") } }
    )
}
