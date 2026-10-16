package com.mohamedt.streamforge.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mohamedt.streamforge.core.Settings

/**
 * Settings → Interface (phone/tablet app only): Automatic / TV (remote) / Touch. Self-contained so
 * it can sit at the top of the settings list; styled like the other settings sections. The TV app
 * is always in the TV interface, so it has no such setting.
 */
@Composable
fun InterfaceSetting() {
    if (DeviceInput.tvBuild) return
    val tv = isTv()
    val context = LocalContext.current
    val mode = InterfaceMode.of(Settings.values.interfaceMode)
    val hardware = DeviceInput.isTvHardware(context)
    val detected = when {
        hardware -> "This device looks like a TV: the StreamForge TV app is made for it."
        formFactor() == FormFactor.TABLET -> "This device was detected as a tablet."
        else -> "This device was detected as a phone."
    }
    Column(Modifier.fillMaxWidth().widthIn(max = 900.dp).padding(vertical = if (tv) 14.dp else 8.dp)) {
        if (tv) {
            Text("Interface", fontSize = 22.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(bottom = 10.dp))
        } else {
            Text("INTERFACE", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Palette.secondary, modifier = Modifier.padding(bottom = 6.dp))
        }
        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(if (tv) 18.dp else 14.dp)).background(Palette.surface).padding(if (tv) 20.dp else 14.dp),
        ) {
            Text("Layout", fontSize = if (tv) 18.sp else 16.sp)
            Row(
                Modifier.horizontalScroll(rememberScrollState()).padding(top = if (tv) 10.dp else 6.dp, bottom = if (tv) 4.dp else 0.dp),
                horizontalArrangement = Arrangement.spacedBy(if (tv) 12.dp else 8.dp),
            ) {
                InterfaceMode.entries.forEach { m ->
                    Chip(m.label, m == mode) {
                        if (m != mode) Settings.update { it.copy(interfaceMode = m.key) }
                    }
                }
            }
        }
        Text(
            "Automatic uses the touch layout (phone or tablet). Choose TV (remote) only if this app is " +
                "running on a TV box; for Android TV and Google TV install the StreamForge TV app instead. $detected",
            fontSize = if (tv) 15.sp else 12.sp, color = Palette.secondary, modifier = Modifier.padding(top = 8.dp),
        )
    }
}
