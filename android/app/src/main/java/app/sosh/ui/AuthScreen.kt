package app.sosh.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
 * address is behind "server" (the emulator's host by default).
 */
@Composable
fun AuthScreen(app: AppState) {
    var mode by rememberSaveable { mutableStateOf(Mode.Login) }
    var email by rememberSaveable { mutableStateOf("") }
    var handle by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    var server by rememberSaveable { mutableStateOf(app.serverUrl) }

    Column(
        Modifier.fillMaxSize().systemBarsPadding().imePadding().verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("sosh", color = Accent, fontSize = 40.sp)
        Text("islands in the sky to hang out on", color = TextDim)
        Spacer(Modifier.height(24.dp))
        val title = when (mode) {
            Mode.Login -> "Sign in"
            Mode.Register -> "Make an account"
            Mode.Confirm -> "Check your email"
            Mode.Forgot -> "Forgot your password"
            Mode.Reset -> "Set a new password"
            Mode.Server -> "Server"
        }
        Text(title, style = MaterialTheme.typography.titleLarge)
        Spacer(Modifier.height(12.dp))
        val field = Modifier.fillMaxWidth().widthIn(max = 420.dp)

        if (mode == Mode.Server) {
            OutlinedTextField(
                server, { server = it }, field, label = { Text("server address") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
            )
            Text("The emulator reaches your computer at http://10.0.2.2:4000", color = TextDim, fontSize = 12.sp)
            Button({ app.setServer(server); mode = Mode.Login }, Modifier.padding(top = 12.dp)) { Text("Use it") }
            return@Column
        }

        OutlinedTextField(
            email, { email = it.trim() }, field, label = { Text("email") }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, imeAction = ImeAction.Next),
        )
        if (mode == Mode.Register) {
            OutlinedTextField(
                handle, { handle = it.filter { c -> c.isLetterOrDigit() || c == '_' }.take(16) }, field,
                label = { Text("handle: what everyone sees") }, singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
            )
        }
        if (mode == Mode.Confirm || mode == Mode.Reset) {
            OutlinedTextField(
                code, { code = it.filter(Char::isDigit).take(6) }, field, label = { Text("6-digit code") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Next),
            )
        }
        if (mode == Mode.Login || mode == Mode.Register || mode == Mode.Reset) {
            OutlinedTextField(
                password, { password = it }, field,
                label = { Text(if (mode == Mode.Login) "password" else "password (10+ characters)") },
                singleLine = true, visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = {
                    if (mode == Mode.Login) app.login(email, password) { if (it == "unconfirmed") mode = Mode.Confirm }
                }),
            )
        }
        Spacer(Modifier.height(16.dp))
        Button(
            onClick = {
                when (mode) {
                    Mode.Login -> app.login(email, password) { if (it == "unconfirmed") mode = Mode.Confirm }
                    Mode.Register -> app.register(email, handle, password) { if (it) mode = Mode.Confirm }
                    Mode.Confirm -> app.confirm(email, code)
                    Mode.Forgot -> app.forgot(email) { mode = Mode.Reset }
                    Mode.Reset -> app.reset(email, code, password)
                    Mode.Server -> {}
                }
            },
            modifier = field,
        ) {
            Text(
                when (mode) {
                    Mode.Login -> "Sign in"
                    Mode.Register -> "Sign up"
                    Mode.Confirm -> "Confirm"
                    Mode.Forgot -> "Email me a code"
                    Mode.Reset -> "Set password"
                    Mode.Server -> ""
                }
            )
        }
        Row(horizontalArrangement = Arrangement.Center) {
            when (mode) {
                Mode.Login -> {
                    TextButton({ mode = Mode.Register }) { Text("New here?") }
                    TextButton({ mode = Mode.Forgot }) { Text("Forgot?") }
                }
                Mode.Register -> {
                    TextButton({ mode = Mode.Login }) { Text("Sign in") }
                    TextButton({ mode = Mode.Confirm }) { Text("Have a code?") }
                }
                Mode.Confirm -> {
                    TextButton({ mode = Mode.Login }) { Text("Sign in") }
                    TextButton({ app.resend(email) }) { Text("Send again") }
                }
                else -> TextButton({ mode = Mode.Login }) { Text("Sign in") }
            }
        }
        TextButton({ mode = Mode.Server }) { Text("server: ${app.serverUrl}", color = TextDim, fontSize = 12.sp) }
    }
}
