package com.mohamedt.streamforge.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.delay

// MARK: Focus memory

/**
 * Remembers which element of a screen had focus, so coming back to the screen (Back from a pushed
 * page, switching tabs) puts focus where it was instead of losing it.
 */
class FocusMemory {
    var last: String? = null
        private set

    /** Key that should grab focus as soon as it is composed (set when the screen is shown again). */
    var pending by mutableStateOf<String?>(null)

    fun record(key: String) {
        last = key
        pending = null
    }

    fun beginRestore() {
        pending = last
    }
}

val LocalFocusMemory = staticCompositionLocalOf<FocusMemory?> { null }

/**
 * TV: focuses [requester] when the screen first appears. If the screen is being re-shown, the
 * remembered element gets focus instead; if that one never shows up, this one does.
 */
@Composable
fun InitialFocus(requester: FocusRequester, key: Any? = Unit, enabled: Boolean = true, always: Boolean = false) {
    val memory = LocalFocusMemory.current
    val tv = isTv()
    LaunchedEffect(key, enabled) {
        if (!tv || !enabled) return@LaunchedEffect
        delay(90)
        val m = memory
        if (always || m == null || m.last == null) {
            runCatching { requester.requestFocus() }
            return@LaunchedEffect
        }
        delay(700)
        val restoring = m ?: return@LaunchedEffect
        if (restoring.pending != null) {
            restoring.pending = null
            runCatching { requester.requestFocus() }
        }
    }
}

// MARK: Keyline scrolling

/** Scrolls so the focused child's leading edge sits on a fixed keyline (TV "pivot" behaviour). */
@OptIn(ExperimentalFoundationApi::class)
private class KeylineSpec(private val keyline: Float) : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float = offset - keyline
}

/** Lazy lists inside [content] keep their focused item at [keyline] from the leading edge (TV only). */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun KeylineScroll(keyline: Dp, enabled: Boolean = true, content: @Composable () -> Unit) {
    if (!enabled) {
        content()
        return
    }
    val px = with(LocalDensity.current) { keyline.toPx() }
    val spec = remember(px) { KeylineSpec(px) }
    CompositionLocalProvider(LocalBringIntoViewSpec provides spec, content = content)
}

// MARK: Buttons

enum class ButtonKind { PRIMARY, SECONDARY, GHOST, DANGER }

/** Pill button. On TV the focused button turns white (Apple TV / Google TV style) and grows a little. */
@Composable
fun SfButton(
    text: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    kind: ButtonKind = ButtonKind.SECONDARY,
    enabled: Boolean = true,
    focusRequester: FocusRequester? = null,
    contentDescription: String? = null,
    onFocus: ((Boolean) -> Unit)? = null,
) {
    val tv = isTv()
    var focused by remember { mutableStateOf(false) }
    val height = if (tv) 52.dp else 42.dp
    val shape = RoundedCornerShape(percent = 50)
    val lit = focused && tv
    val bg = when {
        lit -> SolidColor(Color.White)
        kind == ButtonKind.PRIMARY -> Palette.gradient
        kind == ButtonKind.DANGER -> SolidColor(Palette.live.copy(alpha = 0.22f))
        kind == ButtonKind.GHOST -> SolidColor(Color.Transparent)
        else -> SolidColor(Palette.surfaceHigh)
    }
    val fg = when {
        lit -> Palette.onFocus
        kind == ButtonKind.DANGER -> Color(0xFFFF8A8F)
        else -> Color.White
    }
    val iconOnly = text == null
    val clickable = if (enabled) {
        Modifier.card(onClick, shape = shape, focusScale = if (tv) 1.06f else 1f, border = !tv, glow = kind == ButtonKind.PRIMARY,
            focusRequester = focusRequester, onFocus = { focused = it; onFocus?.invoke(it) })
    } else {
        Modifier.clip(shape)
    }
    Row(
        modifier.height(height).then(if (iconOnly) Modifier.width(height) else Modifier)
            .alpha(if (enabled) 1f else 0.4f)
            .then(clickable)
            .background(bg)
            .padding(horizontal = if (iconOnly) 0.dp else if (tv) 26.dp else 18.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (icon != null) Icon(icon, contentDescription ?: text, tint = fg, modifier = Modifier.size(if (tv) 24.dp else 20.dp))
        if (icon != null && text != null) Spacer(Modifier.width(if (tv) 10.dp else 8.dp))
        if (text != null) Text(text, color = fg, fontSize = if (tv) 18.sp else 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

// MARK: Text input

/**
 * Text field that is safe with a remote: on TV it shows as a large focusable row and only becomes
 * a real text field (opening the system keyboard, including its voice key) when selected, so moving
 * focus across a form never pops the keyboard. Phones get a regular outlined field.
 */
@Composable
fun SfTextField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    label: String? = null,
    secret: Boolean = false,
    icon: ImageVector? = null,
    imeAction: ImeAction = ImeAction.Done,
    onSubmit: (() -> Unit)? = null,
    focusRequester: FocusRequester? = null,
) {
    val tv = isTv()
    val visual = if (secret) PasswordVisualTransformation() else VisualTransformation.None
    val options = KeyboardOptions(keyboardType = if (secret) KeyboardType.Password else KeyboardType.Text, imeAction = imeAction)
    if (!tv) {
        OutlinedTextField(
            value, onValueChange, modifier.fillMaxWidth(),
            label = if (label != null) { { Text(label) } } else null,
            placeholder = if (label == null) { { Text(placeholder) } } else null,
            leadingIcon = if (icon != null) { { Icon(icon, null) } } else null,
            singleLine = true,
            visualTransformation = visual,
            keyboardOptions = options,
            keyboardActions = KeyboardActions(onAny = {
                onSubmit?.invoke()
                defaultKeyboardAction(imeAction)
            }),
        )
        return
    }

    var editing by remember { mutableStateOf(false) }
    var gotFocus by remember { mutableStateOf(false) }
    var refocus by remember { mutableStateOf(false) }
    val field = remember { FocusRequester() }
    val own = remember { FocusRequester() }
    val display = focusRequester ?: own
    val keyboard = LocalSoftwareKeyboardController.current
    val finish = {
        keyboard?.hide()
        refocus = true
        editing = false
    }
    Column(modifier.fillMaxWidth()) {
        if (label != null) Text(label, fontSize = 15.sp, color = Palette.secondary, modifier = Modifier.padding(start = 4.dp, bottom = 6.dp))
        if (editing) {
            OutlinedTextField(
                value, onValueChange,
                Modifier.fillMaxWidth().focusRequester(field).onFocusChanged { s ->
                    if (s.isFocused) gotFocus = true else if (gotFocus) { gotFocus = false; editing = false }
                },
                placeholder = { Text(placeholder, fontSize = 18.sp) },
                leadingIcon = if (icon != null) { { Icon(icon, null, modifier = Modifier.size(26.dp)) } } else null,
                singleLine = true,
                textStyle = TextStyle(fontSize = 20.sp, color = Color.White),
                visualTransformation = visual,
                keyboardOptions = options,
                keyboardActions = KeyboardActions(onAny = {
                    onSubmit?.invoke()
                    finish()
                }),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Palette.accent,
                    unfocusedBorderColor = Palette.surfaceHigh,
                    cursorColor = Palette.accent,
                ),
            )
            LaunchedEffect(Unit) {
                delay(60)
                runCatching { field.requestFocus() }
                keyboard?.show()
            }
            BackHandler { finish() }
        } else {
            var focused by remember { mutableStateOf(false) }
            Row(
                Modifier.fillMaxWidth().height(60.dp)
                    .card({ editing = true }, shape = RoundedCornerShape(14.dp), focusScale = 1.02f, border = false, glow = false,
                        focusRequester = display, onFocus = { focused = it })
                    .background(if (focused) Color.White else Palette.surfaceHigh)
                    .padding(horizontal = 20.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (icon != null) {
                    Icon(icon, null, tint = if (focused) Palette.onFocus else Palette.secondary, modifier = Modifier.size(26.dp))
                    Spacer(Modifier.width(14.dp))
                }
                val shown = when {
                    value.isEmpty() -> placeholder
                    secret -> "•".repeat(value.length.coerceAtMost(24))
                    else -> value
                }
                val color = when {
                    focused && value.isEmpty() -> Palette.onFocus.copy(alpha = 0.55f)
                    focused -> Palette.onFocus
                    value.isEmpty() -> Palette.secondary
                    else -> Color.White
                }
                Text(shown, fontSize = 19.sp, color = color, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            LaunchedEffect(refocus) {
                if (refocus) {
                    refocus = false
                    delay(60)
                    runCatching { display.requestFocus() }
                }
            }
        }
    }
}

// MARK: Panels

/**
 * Dialog that suits the device: a full-height side panel with large rows on TV (focus stays inside,
 * Back closes it), a regular alert dialog on phones and tablets.
 */
@Composable
fun SfDialog(
    title: String,
    onDismiss: () -> Unit,
    subtitle: String? = null,
    actions: (@Composable RowScope.() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    if (!isTv()) {
        val dismissButton: (@Composable () -> Unit)? = if (actions != null) {
            { Row(verticalAlignment = Alignment.CenterVertically, content = actions) }
        } else null
        AlertDialog(
            onDismissRequest = onDismiss,
            confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
            dismissButton = dismissButton,
            title = {
                Column {
                    Text(title)
                    if (subtitle != null) Text(subtitle, fontSize = 13.sp, color = Palette.secondary)
                }
            },
            text = { Column(content = content) },
        )
        return
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(listOf(Color.Black.copy(alpha = 0.15f), Color.Black.copy(alpha = 0.7f)))))
            Column(
                Modifier.align(Alignment.CenterEnd).fillMaxHeight().fillMaxWidth(0.48f)
                    .background(Palette.raised)
                    .padding(start = 36.dp, end = 48.dp, top = Dims.overscanY + 8.dp, bottom = Dims.overscanY),
            ) {
                Text(title, fontSize = 28.sp, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                if (subtitle != null) {
                    Spacer(Modifier.height(4.dp))
                    Text(subtitle, fontSize = 16.sp, color = Palette.secondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                if (actions != null) {
                    Spacer(Modifier.height(16.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically, content = actions)
                }
                Spacer(Modifier.height(16.dp))
                Column(Modifier.weight(1f).fillMaxWidth(), content = content)
            }
        }
    }
}

/** A large focusable row for TV lists and panels: title, optional detail, selected tick. */
@Composable
fun SfListRow(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    detail: String? = null,
    selected: Boolean = false,
    focusRequester: FocusRequester? = null,
    trailing: String? = null,
) {
    val tv = isTv()
    var focused by remember { mutableStateOf(false) }
    val lit = focused && tv
    Row(
        modifier.fillMaxWidth()
            .card(onClick, shape = RoundedCornerShape(12.dp), focusScale = if (tv) 1.02f else 1f, border = !tv, glow = false,
                focusRequester = focusRequester, onFocus = { focused = it })
            .background(if (lit) Color.White else if (selected) Palette.surfaceHigh else Color.Transparent)
            .padding(horizontal = if (tv) 18.dp else 10.dp, vertical = if (tv) 14.dp else 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = if (tv) 19.sp else 15.sp, fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                color = if (lit) Palette.onFocus else Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (detail != null) {
                Text(detail, fontSize = if (tv) 15.sp else 12.sp, color = if (lit) Palette.onFocus.copy(alpha = 0.7f) else Palette.secondary,
                    maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
        if (trailing != null) {
            Spacer(Modifier.width(10.dp))
            Text(trailing, fontSize = if (tv) 15.sp else 12.sp, color = if (lit) Palette.onFocus.copy(alpha = 0.7f) else Palette.secondary)
        }
        if (selected) {
            Spacer(Modifier.width(10.dp))
            Text("✓", fontSize = if (tv) 20.sp else 16.sp, fontWeight = FontWeight.Bold, color = if (lit) Palette.onFocus else Palette.accent)
        }
    }
}
