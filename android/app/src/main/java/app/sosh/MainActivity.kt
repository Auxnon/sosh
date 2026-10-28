package app.sosh

import android.os.Bundle
import android.view.KeyEvent
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import app.sosh.ui.AuthScreen
import app.sosh.ui.BagScreen
import app.sosh.ui.Centered
import app.sosh.ui.ChatScreen
import app.sosh.ui.CreatorScreen
import app.sosh.ui.ExploreScreen
import app.sosh.ui.FriendsScreen
import app.sosh.ui.Gamepad
import app.sosh.ui.MembersScreen
import app.sosh.ui.Screen
import app.sosh.ui.SoshTheme
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    private lateinit var app: AppState

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        app = AppState(applicationContext, lifecycleScope)
        setContent {
            SoshTheme {
                var screen by remember { mutableStateOf(Screen.Chat) }
                val back = { screen = Screen.Chat }
                BackHandler(enabled = screen != Screen.Chat) { back() }
                Box(Modifier.fillMaxSize()) {
                    when {
                        app.me == null && app.restoring -> Centered("signing in...")
                        app.me == null -> AuthScreen(app)
                        else -> when (screen) {
                            Screen.Chat -> ChatScreen(app) { screen = it }
                            Screen.Explore -> ExploreScreen(app, back)
                            Screen.Friends -> FriendsScreen(app, back) { h -> app.open(Place.WithPerson(h)); back() }
                            Screen.Bag -> BagScreen(app, back)
                            Screen.Creator -> CreatorScreen(app, back)
                            Screen.Members -> MembersScreen(app, back)
                        }
                    }
                    app.notice?.let { n ->
                        LaunchedEffect(n) {
                            delay(3500)
                            if (app.notice == n) app.notice = null
                        }
                        Snackbar(Modifier.align(Alignment.BottomCenter).systemBarsPadding().padding(16.dp)) { Text(n) }
                    }
                }
            }
        }
    }

    // a controller drives the world that's showing, if one is
    override fun dispatchKeyEvent(event: KeyEvent): Boolean = Gamepad.key(event) || super.dispatchKeyEvent(event)

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean =
        Gamepad.motion(event) || super.dispatchGenericMotionEvent(event)
}
