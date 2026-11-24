package com.magicmaker.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.magicmaker.android.BuildConfig
import com.magicmaker.android.MagicMakerApp
import com.magicmaker.android.service.ServiceState
import com.magicmaker.android.sync.PacketSync

/** What the CLOUD DICTIONARY section says under its title (both themes). */
internal const val CLOUD_TOKEN_EXPLANATION: String =
    "Shared packets.csv sync. Paste a GitHub fine-grained token with Contents: Read and write on " +
        "the dictionary repo only. It stays on this phone and is never in library exports. " +
        "Empty = cloud sync off."

/** One-line state of the cloud token: entered here, built in (local private build), or none. */
internal fun cloudTokenStateText(enteredSet: Boolean): String = when {
    enteredSet -> "TOKEN: SET ON THIS PHONE"
    BuildConfig.BACKUP_TOKEN.isNotBlank() -> "TOKEN: BUILT INTO THIS BUILD"
    else -> "TOKEN: NOT SET · SYNC OFF"
}

/** SETTINGS -> CLOUD DICTIONARY: the "Cloud dictionary token" field. The token is entered once on
 *  the device (release APKs carry none, the repo is public), kept by PacketSync in its own
 *  app-private prefs file and never shown again; SAVE syncs at once, CLEAR turns sync off. */
@Composable
internal fun CloudTokenSettingsSection(app: MagicMakerApp) {
    val ctx = LocalContext.current
    var entered by remember { mutableStateOf(PacketSync.enteredToken(ctx)) }
    var draft by remember { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text("CLOUD DICTIONARY", style = techHeader())
        Text(CLOUD_TOKEN_EXPLANATION, style = techLabel(), color = AppColors.TextDim)
        Text("REPO: ${BuildConfig.BACKUP_REPO}", style = techLabel(), color = AppColors.TextDim)
        Text(
            cloudTokenStateText(entered.isNotBlank()),
            style = techLabel(),
            color = if (entered.isNotBlank()) AppColors.Cyan else AppColors.TextDim,
        )
        OutlinedTextField(
            value = draft,
            onValueChange = { draft = it },
            singleLine = true,
            textStyle = techLabel(),
            label = { Text("Cloud dictionary token", style = techLabel()) },
            placeholder = { Text("github_pat_…", style = techLabel(), color = AppColors.TextDim) },
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrect = false,
                keyboardType = KeyboardType.Password,
            ),
            modifier = Modifier.fillMaxWidth(),
        )
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(AppDimens.gap),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedButton(
                onClick = {
                    PacketSync.saveToken(ctx, draft)
                    entered = PacketSync.enteredToken(ctx)
                    draft = ""
                    app.store.cloudSync(force = true)
                },
                enabled = draft.isNotBlank(),
                modifier = Modifier.height(28.dp),
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
            ) { Text("SAVE", style = techLabel()) }
            OutlinedButton(
                onClick = {
                    PacketSync.saveToken(ctx, "")
                    entered = ""
                    ServiceState.setCloudSyncStatus("")
                },
                enabled = entered.isNotBlank(),
                modifier = Modifier.height(28.dp),
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
            ) { Text("CLEAR", style = techLabel()) }
        }
    }
}
