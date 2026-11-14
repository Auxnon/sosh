package app.sosh.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.sosh.AppState
import app.sosh.BuildConfig
import app.sosh.Update

/**
 * The server needs a newer app (`Sosh.Clients`): nothing else works until
 * then, so this is all there is, with the way to the download.
 */
@Composable
fun UpdateScreen(app: AppState, u: Update) {
    val context = LocalContext.current
    Column(
        Modifier.fillMaxSize().systemBarsPadding().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Column(
            Modifier.widthIn(max = 420.dp).fillMaxWidth().paper().padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("Time to update", color = Ink, fontWeight = FontWeight.ExtraBold, fontSize = 22.sp)
            Text(
                "${app.serverUrl.removePrefix("https://")} needs sosh ${u.min} or newer. This is ${BuildConfig.VERSION_NAME}.",
                color = InkDim, fontSize = 15.sp, textAlign = TextAlign.Center,
            )
            PlasticButton({
                runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(u.download)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            }, tone = Tone.Orange) { Text("Get the new version", fontWeight = FontWeight.ExtraBold) }
            TextButton({ app.signOutToServerPicker() }) { Text("Use another server", color = InkLink) }
        }
    }
}
