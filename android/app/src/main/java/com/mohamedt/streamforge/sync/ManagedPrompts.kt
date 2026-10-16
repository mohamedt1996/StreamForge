package com.mohamedt.streamforge.sync

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.SfDialog
import com.mohamedt.streamforge.ui.SfListRow
import com.mohamedt.streamforge.ui.isTv
import kotlinx.coroutines.delay

/** An admin-managed item (PROTOCOL.md §5) shown in a prompt or in the list of items this account continues without. */
data class ManagedItem(
    /** Record key "<collection>/<id>". */
    val key: String,
    val collection: String,
    val itemId: String,
    val name: String,
)

/** A removal that needs the "Set up by your server" confirmation because the item is managed. */
class ManagedRemoval(val item: ManagedItem, val perform: () -> Unit)

fun managedKindLabel(collection: String): String = when (collection) {
    "servers" -> "Dispatcharr server"
    "addons" -> "Addon"
    "settings" -> "Setting"
    else -> collection
}

private fun joinedNames(items: List<ManagedItem>): String {
    val names = items.map { "“${it.name}”" }
    return when (names.size) {
        0 -> ""
        1 -> names[0]
        else -> names.dropLast(1).joinToString(", ") + " and " + names.last()
    }
}

/**
 * Two-choice dialog that suits the device: an alert on phones and tablets; on TV a side panel with
 * large focusable rows (focus starts on the safe choice, Back = [onDismiss]).
 */
@Composable
private fun ManagedDialog(
    message: String,
    safeLabel: String,
    onSafe: () -> Unit,
    otherLabel: String,
    onOther: () -> Unit,
    onDismiss: () -> Unit,
) {
    val title = "Set up by your server"
    if (!isTv()) {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text(title) },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = onOther) { Text(otherLabel, color = Palette.live) } },
            dismissButton = { TextButton(onClick = onSafe) { Text(safeLabel) } },
        )
        return
    }
    val first = remember { FocusRequester() }
    SfDialog(title = title, onDismiss = onDismiss) {
        Text(message, fontSize = 18.sp, color = Palette.secondary)
        Spacer(Modifier.height(20.dp))
        SfListRow(safeLabel, onSafe, focusRequester = first)
        SfListRow(otherLabel, onOther)
    }
    LaunchedEffect(Unit) {
        delay(150) // the dialog window composes after this
        runCatching { first.requestFocus() }
    }
}

/** Confirmation before removing an admin-managed addon or Dispatcharr server. */
@Composable
fun ManagedRemovalDialog(removal: ManagedRemoval, onClose: () -> Unit) {
    ManagedDialog(
        message = "“${removal.item.name}” was added for you by your StreamForge server admin. Removing it here removes it on all your devices.",
        safeLabel = "Keep it",
        onSafe = onClose,
        otherLabel = "Remove from this account",
        onOther = {
            ServerSync.dismiss(removal.item.collection, removal.item.itemId)
            removal.perform()
            onClose()
        },
        onDismiss = onClose,
    )
}

/** App-wide prompts: managed items sync brought back after a local removal, and changed managed settings. */
@Composable
fun ManagedSyncPrompts() {
    val settings = ServerSync.settingPrompt
    val restore = ServerSync.restorePrompt
    when {
        settings.isNotEmpty() -> ManagedDialog(
            message = "${joinedNames(settings)} ${if (settings.size == 1) "was" else "were"} set for you by your StreamForge server admin. " +
                "Keep the server's value, or remove it from this account and use your own on all your devices?",
            safeLabel = "Keep it",
            onSafe = { ServerSync.keepManagedSettings() },
            otherLabel = "Remove from this account",
            onOther = { ServerSync.releaseManagedSettings() },
            onDismiss = { ServerSync.keepManagedSettings() },
        )
        restore.isNotEmpty() && !ServerSync.restorePromptSnoozed -> {
            val one = restore.size == 1
            ManagedDialog(
                message = "${joinedNames(restore)} ${if (one) "was" else "were"} added for you by your StreamForge server admin. " +
                    "You removed ${if (one) "it" else "them"} on this device: restore ${if (one) "it" else "them"} from sync, " +
                    "or continue without ${if (one) "it" else "them"} on all your devices?",
                safeLabel = "Restore from sync",
                onSafe = { ServerSync.restoreHeld() },
                otherLabel = "Continue without it",
                onOther = { ServerSync.continueWithoutHeld() },
                onDismiss = { ServerSync.restorePromptSnoozed = true },
            )
        }
    }
}
