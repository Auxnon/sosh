package app.sosh.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.sosh.AppState

private enum class Mode { Login, Register, Confirm, Forgot, Reset, Server }

/**
 * Signing in, by email. A new account is confirmed with the 6-digit code
 * emailed to it; a forgotten password is reset with another. The server's
 * address is behind the chip at the bottom (the emulator's host by default).
 */
@Composable
fun AuthScreen(app: AppState) {
    var mode by rememberSaveable { mutableStateOf(Mode.Login) }
    var email by rememberSaveable { mutableStateOf("") }
    var handle by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    var server by rememberSaveable { mutableStateOf(app.serverUrl) }
    val login = { app.login(email, password) { if (it == "unconfirmed") mode = Mode.Confirm } }

    Column(
        Modifier.fillMaxSize().ground().systemBarsPadding().imePadding().verticalScroll(rememberScrollState()).padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        CubeLogo(Modifier.size(120.dp, 128.dp))
        Text("sosh", color = Paper, fontSize = 52.sp, fontWeight = FontWeight.ExtraBold, lineHeight = 56.sp)
        Label("islands in the sky", style = TechLabel.copy(fontSize = 10.sp, letterSpacing = 2.sp))
        Spacer(Modifier.height(20.dp))
        Column(
            Modifier.fillMaxWidth().widthIn(max = 440.dp).paper(RoundedCornerShape(28.dp), drop = 5.dp).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                when (mode) {
                    Mode.Login -> "Sign in"
                    Mode.Register -> "Make an account"
                    Mode.Confirm -> "Check your email"
                    Mode.Forgot -> "Forgot your password"
                    Mode.Reset -> "Set a new password"
                    Mode.Server -> "Server"
                },
                style = MaterialTheme.typography.titleLarge, color = Ink,
            )
            if (mode == Mode.Server) {
                Field("server address", server, { server = it }, KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done))
                Text("The emulator reaches your computer at http://10.0.2.2:4000", color = InkDim, fontSize = 12.sp)
                PlasticButton({ app.setServer(server); mode = Mode.Login }, Modifier.fillMaxWidth().height(52.dp), tone = Tone.Green) {
                    Text("Use it", fontWeight = FontWeight.ExtraBold, fontSize = 16.sp)
                }
                return@Column
            }
            Field("email", email, { email = it.trim() }, KeyboardOptions(keyboardType = KeyboardType.Email, imeAction = ImeAction.Next))
            if (mode == Mode.Register) {
                Field(
                    "handle: what everyone sees", handle, { handle = it.filter { c -> c.isLetterOrDigit() || c == '_' }.take(16) },
                    KeyboardOptions(imeAction = ImeAction.Next),
                )
            }
            if (mode == Mode.Confirm || mode == Mode.Reset) {
                Field(
                    "6-digit code", code, { code = it.filter(Char::isDigit).take(6) },
                    KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Next),
                )
            }
            if (mode == Mode.Login || mode == Mode.Register || mode == Mode.Reset) {
                Field(
                    if (mode == Mode.Login) "password" else "password (10+ characters)", password, { password = it },
                    KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                    secret = true, done = { if (mode == Mode.Login) login() },
                )
            }
            PlasticButton(
                {
                    when (mode) {
                        Mode.Login -> login()
                        Mode.Register -> app.register(email, handle, password) { if (it) mode = Mode.Confirm }
                        Mode.Confirm -> app.confirm(email, code)
                        Mode.Forgot -> app.forgot(email) { mode = Mode.Reset }
                        Mode.Reset -> app.reset(email, code, password)
                        Mode.Server -> {}
                    }
                },
                Modifier.fillMaxWidth().height(52.dp).padding(top = 4.dp), tone = Tone.Green,
            ) {
                Text(
                    when (mode) {
                        Mode.Login -> "Sign in"
                        Mode.Register -> "Sign up"
                        Mode.Confirm -> "Confirm"
                        Mode.Forgot -> "Email me a code"
                        Mode.Reset -> "Set password"
                        Mode.Server -> ""
                    },
                    fontWeight = FontWeight.ExtraBold, fontSize = 16.sp,
                )
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                when (mode) {
                    Mode.Login -> {
                        Link("New here?") { mode = Mode.Register }
                        Link("Forgot?") { mode = Mode.Forgot }
                    }
                    Mode.Register -> {
                        Link("Sign in") { mode = Mode.Login }
                        Link("Have a code?") { mode = Mode.Confirm }
                    }
                    Mode.Confirm -> {
                        Link("Sign in") { mode = Mode.Login }
                        Link("Send again") { app.resend(email) }
                    }
                    else -> Link("Sign in") { mode = Mode.Login }
                }
            }
        }
        Spacer(Modifier.height(18.dp))
        PlasticButton({ mode = Mode.Server }) {
            Label("server · ${app.serverUrl.substringAfter("://")}")
        }
    }
}

@Composable
private fun Link(text: String, onClick: () -> Unit) {
    TextButton(onClick) { Text(text, color = InkLink, fontWeight = FontWeight.Bold, fontSize = 14.sp) }
}

/** A text field on paper. */
@Composable
private fun Field(
    label: String, value: String, change: (String) -> Unit, keyboard: KeyboardOptions,
    secret: Boolean = false, done: () -> Unit = {},
) {
    OutlinedTextField(
        value, change, Modifier.fillMaxWidth(),
        label = { Text(label) }, singleLine = true,
        visualTransformation = if (secret) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        keyboardOptions = keyboard, keyboardActions = KeyboardActions(onDone = { done() }),
        shape = RoundedCornerShape(16.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = Ink, unfocusedTextColor = Ink, cursorColor = Ink,
            focusedContainerColor = Color(0xFFFFFBEE), unfocusedContainerColor = Color(0xFFFFFBEE),
            focusedBorderColor = Accent, unfocusedBorderColor = Color(0xFFE3CC98),
            focusedLabelColor = InkLink, unfocusedLabelColor = InkFaint,
        ),
    )
}

/** A little floating island inside a plastic cube: the boot screen's logo. */
@Composable
private fun CubeLogo(modifier: Modifier) {
    Canvas(modifier) {
        val u = size.width / 132f
        fun p(vararg xy: Float) = Path().apply {
            moveTo(xy[0] * u, xy[1] * u)
            for (i in 2 until xy.size step 2) lineTo(xy[i] * u, xy[i + 1] * u)
            close()
        }
        drawPath(p(66f, 6f, 122f, 36f, 122f, 100f, 66f, 134f, 10f, 100f, 10f, 36f), Panel)
        drawPath(p(66f, 6f, 122f, 36f, 66f, 66f, 10f, 36f), Color(0xFF5A50B8))
        drawPath(p(10f, 36f, 66f, 66f, 66f, 134f, 10f, 100f), Color(0xFF2E2768))
        drawPath(p(66f, 6f, 122f, 36f, 66f, 66f, 10f, 36f), Color(0xFF8B82D8), style = Stroke(2 * u))
        drawPath(p(40f, 40f, 92f, 40f, 82f, 58f, 50f, 58f), Color(0xFFB07A45))
        drawOval(Color(0xFF7CCB5A), Offset(36f * u, 26f * u), Size(60f * u, 24f * u))
        drawRect(Color(0xFF7A5230), Offset(54f * u, 28f * u), Size(4f * u, 8f * u))
        drawCircle(Color(0xFF4FA83A), 9f * u, Offset(56f * u, 26f * u))
        drawRoundRect(Paper, Offset(72f * u, 26f * u), Size(8f * u, 10f * u), CornerRadius(3f * u))
    }
}
