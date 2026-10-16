package com.mohamedt.streamforge.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** Touch swipe removal plus an explicit, remote-accessible saved toggle. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WatchlistCard(item: com.mohamedt.streamforge.core.MediaItem, onClick: () -> Unit) {
    val toggle = LocalWatchlistAction.current
    val currentToggle by rememberUpdatedState(toggle)
    val tv = isTv()
    val state = rememberSwipeToDismissBoxState()
    LaunchedEffect(state.currentValue) {
        if (state.currentValue != SwipeToDismissBoxValue.Settled) {
            currentToggle(item)
            state.reset()
        }
    }
    Column(Modifier.width(Dims.poster())) {
        SwipeToDismissBox(state = state, enableDismissFromStartToEnd = !tv, enableDismissFromEndToStart = !tv,
            backgroundContent = {
                Box(Modifier.fillMaxSize().background(Palette.live), contentAlignment = Alignment.Center) {
                    Text("Remove", style = MaterialTheme.typography.labelLarge)
                }
            }) {
            PosterCard(item, onClick, { currentToggle(item) })
        }
        TextButton(onClick = { currentToggle(item) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
            Text("Remove", style = MaterialTheme.typography.labelLarge)
        }
    }
}
