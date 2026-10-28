package app.sosh.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CardGiftcard
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.VerticalSplit
import androidx.compose.material.icons.filled.Face
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Mail
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Public
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.sosh.AppState
import app.sosh.Pane
import app.sosh.Place
import app.sosh.data.Message
import app.sosh.data.Server
import kotlinx.coroutines.launch

enum class Screen { Chat, Explore, Friends, Bag, Creator, Members }

/**
 * The app once signed in: a drawer with the server rail (Discord style)
 * and what's in the selected place, and the chat pane.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun ChatScreen(app: AppState, go: (Screen) -> Unit) {
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    var giftOpen by remember { mutableStateOf(false) }
    BackHandler(enabled = app.place is Place.InServer && app.pane != Pane.Chat) { app.pane = Pane.Chat }

    ModalNavigationDrawer(
        drawerState = drawer,
        drawerContent = {
            ModalDrawerSheet(drawerContainerColor = Night, modifier = Modifier.width(320.dp)) {
                Drawer(app, go) { scope.launch { drawer.close() } }
            }
        },
    ) {
        Scaffold(
            topBar = {
                TopAppBar(
                    navigationIcon = {
                        IconButton({ scope.launch { drawer.open() } }) { Icon(Icons.Filled.Menu, "servers") }
                    },
                    title = { PlaceTitle(app) },
                    actions = {
                        val p = app.place
                        if (p is Place.InServer) {
                            IconButton({ go(Screen.Members) }) { Icon(Icons.Filled.Group, "members") }
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = Panel),
                )
            },
            containerColor = Night,
        ) { pad ->
            Column(Modifier.fillMaxSize().padding(pad).imePadding()) {
                when (val p = app.place) {
                    null -> Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                        Text("Pick a server or a friend from the menu.", color = TextDim)
                    }
                    is Place.InServer -> {
                        ServerView(app, p.id, Modifier.weight(1f))
                        Composer(app) { giftOpen = true }
                        if (!WindowInsets.isImeVisible) PaneBar(app)
                    }
                    is Place.WithPerson -> {
                        Messages(app, Modifier.weight(1f))
                        Composer(app) { giftOpen = true }
                    }
                }
            }
        }
    }
    if (giftOpen) GiftDialog(app) { giftOpen = false }
}

/**
 * A server: its chat, its world, or both. The world slides down over the
 * chat (in from the side, with the phone on its side) and back out. Once
 * opened it stays loaded, only paused while it's away, until we leave
 * the server.
 */
@Composable
private fun ServerView(app: AppState, serverId: Long, modifier: Modifier) {
    var started by remember(serverId) { mutableStateOf(false) }
    LaunchedEffect(serverId, app.pane) { if (app.pane != Pane.Chat) started = true }
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val w = maxWidth
        val h = maxHeight
        val wide = w > h
        val target = when (app.pane) {
            Pane.Chat -> 0f
            Pane.Both -> if (wide) 0.6f else 0.5f
            Pane.World -> 1f
        }
        val share by animateFloatAsState(target, label = "world")
        val world: @Composable (Modifier) -> Unit = { m ->
            if (started) key(serverId) { WorldPane(app, serverId, app.pane != Pane.Chat, m) }
        }
        if (wide) {
            Row(Modifier.fillMaxSize()) {
                world(Modifier.fillMaxHeight().width(w * share))
                if (share < 1f) Messages(app, Modifier.weight(1f))
            }
        } else {
            Column(Modifier.fillMaxSize()) {
                world(Modifier.fillMaxWidth().height(h * share))
                if (share < 1f) Messages(app, Modifier.weight(1f))
            }
        }
        if (app.pane == Pane.World && share == 1f) Overlay(app, Modifier.align(Alignment.BottomStart))
    }
}

/**
 * All world: the latest few lines over it, as the game's own chat log was.
 * Tapping them brings the chat back beside it.
 */
@Composable
private fun Overlay(app: AppState, modifier: Modifier) {
    Column(
        modifier.fillMaxWidth(0.8f).padding(8.dp).clickable { app.pane = Pane.Both },
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        for (m in app.messages.takeLast(4)) {
            val who = m.author?.handle ?: "someone"
            val line = buildAnnotatedString {
                withStyle(SpanStyle(color = handleColor(who), fontWeight = FontWeight.Bold)) { append(who) }
                append("  ")
                val g = m.gift
                if (g != null) append("a gift for @${g.to?.handle ?: "someone"}") else append(mentions(m.body, app.me?.handle))
            }
            Text(
                line, color = TextMain, fontSize = 13.sp, maxLines = 2,
                modifier = Modifier.background(Night.copy(alpha = 0.6f), RoundedCornerShape(6.dp)).padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
    }
}

/** Chat, both, or the world: one tap between them. */
@Composable
private fun PaneBar(app: AppState) {
    val options = listOf(
        Triple(Pane.Chat, "Chat", Icons.Filled.ChatBubble),
        Triple(Pane.Both, "Both", Icons.Filled.VerticalSplit),
        Triple(Pane.World, "World", Icons.Filled.Public),
    )
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().background(Panel).padding(horizontal = 8.dp, vertical = 4.dp)) {
        options.forEachIndexed { i, (pane, label, icon) ->
            SegmentedButton(
                selected = app.pane == pane,
                onClick = { app.pane = pane },
                shape = SegmentedButtonDefaults.itemShape(i, options.size),
                icon = { Icon(icon, null, Modifier.size(18.dp)) },
            ) { Text(label) }
        }
    }
}

@Composable
private fun PlaceTitle(app: AppState) {
    when (val p = app.place) {
        is Place.InServer -> {
            val s = app.server(p.id)
            Column {
                Text(s?.name ?: "server", fontWeight = FontWeight.Bold)
                Text(
                    if (app.online) "${s?.members ?: 0} members" else "connecting...",
                    fontSize = 12.sp, color = TextDim,
                )
            }
        }
        is Place.WithPerson -> Text("@${p.handle}", fontWeight = FontWeight.Bold)
        null -> Text("sosh")
    }
}

/** The rail of servers and shortcuts, and the list beside it. */
@Composable
private fun Drawer(app: AppState, go: (Screen) -> Unit, close: () -> Unit) {
    var dms by remember { mutableStateOf(app.place is Place.WithPerson) }
    Row(Modifier.fillMaxHeight()) {
        Column(
            Modifier.width(72.dp).fillMaxHeight().background(Color(0xFF0E131C)).verticalScroll(rememberScrollState()).padding(vertical = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            RailIcon("DM", dms, Icons.Filled.Mail) { dms = true }
            HorizontalDivider(Modifier.width(32.dp), color = PanelHi)
            for (s in app.servers.filter { it.isMember }) {
                val on = !dms && app.place == Place.InServer(s.id)
                RailIcon(initials(s.name), on, null) {
                    dms = false
                    app.open(Place.InServer(s.id))
                    close()
                }
            }
            RailIcon("+", false, Icons.Filled.Add) { go(Screen.Explore); close() }
            Spacer(Modifier.height(8.dp))
            RailIcon("friends", false, Icons.Filled.People) { go(Screen.Friends); close() }
            RailIcon("bag", false, Icons.Filled.Inventory2) { go(Screen.Bag); close() }
            RailIcon("look", false, Icons.Filled.Face) { go(Screen.Creator); close() }
        }
        Column(Modifier.weight(1f).fillMaxHeight().padding(12.dp)) {
            val me = app.me
            if (dms) {
                Text("Direct messages", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(8.dp))
                LazyColumn(Modifier.weight(1f)) {
                    items(app.friends.friends) { f ->
                        val c = app.conversations.firstOrNull { it.with.handle == f.handle }
                        DmRow(f.handle, c?.last?.body) { app.open(Place.WithPerson(f.handle)); close() }
                    }
                    items(app.conversations.filter { c -> app.friends.friends.none { it.handle == c.with.handle } }) { c ->
                        DmRow(c.with.handle, c.last?.body) { app.open(Place.WithPerson(c.with.handle)); close() }
                    }
                }
            } else {
                val s = (app.place as? Place.InServer)?.let { app.server(it.id) }
                if (s != null) {
                    Text(s.name, style = MaterialTheme.typography.titleMedium)
                    Text(s.description, color = TextDim, fontSize = 13.sp)
                    Spacer(Modifier.height(8.dp))
                    Text("universe ${s.universe.first},${s.universe.second} · ${s.policy}", color = TextDim, fontSize = 12.sp)
                    Text("you: ${s.role ?: "member"}", color = TextDim, fontSize = 12.sp)
                    Spacer(Modifier.height(12.dp))
                    Button({ app.pane = Pane.World; close() }, Modifier.fillMaxWidth()) { Text("Enter the world") }
                    OutlinedButton({ go(Screen.Members); close() }, Modifier.fillMaxWidth()) { Text("Members") }
                } else {
                    Text("Servers", style = MaterialTheme.typography.titleMedium)
                }
                Spacer(Modifier.weight(1f))
            }
            if (me != null) {
                HorizontalDivider(color = PanelHi)
                Row(Modifier.padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("@${me.handle}", color = handleColor(me.handle), modifier = Modifier.weight(1f))
                    TextButton({ app.logout() }) { Text("Sign out") }
                }
            }
        }
    }
}

@Composable
private fun DmRow(handle: String, last: String?, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 8.dp)) {
        Text("@$handle", color = handleColor(handle))
        if (!last.isNullOrEmpty()) Text(last, color = TextDim, fontSize = 12.sp, maxLines = 1)
    }
}

@Composable
private fun RailIcon(label: String, selected: Boolean, icon: androidx.compose.ui.graphics.vector.ImageVector?, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = if (selected) RoundedCornerShape(16.dp) else CircleShape,
        color = if (selected) Accent else PanelHi,
        modifier = Modifier.size(48.dp),
    ) {
        Box(contentAlignment = Alignment.Center) {
            if (icon != null) Icon(icon, label, tint = if (selected) Night else TextMain)
            else Text(label, color = if (selected) Night else TextMain, fontWeight = FontWeight.Bold)
        }
    }
}

fun initials(name: String): String =
    name.split(' ').filter { it.isNotEmpty() }.take(2).joinToString("") { it.take(1).uppercase() }.ifEmpty { "?" }

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun Messages(app: AppState, modifier: Modifier) {
    val list = rememberLazyListState()
    val n = app.messages.size
    LaunchedEffect(n) { if (n > 0) list.animateScrollToItem(n - 1) }
    var menuFor by remember { mutableStateOf<Message?>(null) }
    LazyColumn(modifier.fillMaxWidth().padding(horizontal = 12.dp), state = list) {
        item {
            if (n >= 50) TextButton({ app.loadOlder() }) { Text(if (app.loadingOlder) "loading..." else "Older messages") }
        }
        items(app.messages, key = { it.id }) { m ->
            Column(Modifier.fillMaxWidth().combinedClickable(onClick = {}, onLongClick = { menuFor = m }).padding(vertical = 6.dp)) {
                val who = m.author?.handle ?: "someone"
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(who, color = handleColor(who), fontWeight = FontWeight.Bold)
                    Spacer(Modifier.width(8.dp))
                    Text(m.at.take(16).replace('T', ' '), color = TextDim, fontSize = 11.sp)
                }
                if (m.body.isNotEmpty()) Text(mentions(m.body, app.me?.handle))
                m.gift?.let { GiftCard(app, m) }
            }
        }
    }
    menuFor?.let { m ->
        val mine = m.author?.id == app.me?.id
        val mod = (app.place as? Place.InServer)?.let { app.server(it.id)?.can("manage_messages") } == true
        AlertDialog(
            onDismissRequest = { menuFor = null },
            title = { Text("Message") },
            text = { Text(m.body.ifEmpty { "(a gift)" }) },
            confirmButton = {
                if (mine || mod) TextButton({ app.deleteMessage(m); menuFor = null }) { Text("Delete", color = Bad) }
            },
            dismissButton = { TextButton({ menuFor = null }) { Text("Close") } },
        )
    }
}

/** @handles highlighted, ours most of all. */
fun mentions(body: String, me: String?) = buildAnnotatedString {
    val words = body.split(' ')
    words.forEachIndexed { i, w ->
        if (w.startsWith("@") && w.length > 1) {
            val isMe = me != null && w.drop(1).trimEnd(',', '.', '!', '?', ':').equals(me, ignoreCase = true)
            withStyle(SpanStyle(color = if (isMe) Night else Accent, background = if (isMe) Accent else Color.Transparent, fontWeight = FontWeight.Bold)) {
                append(w)
            }
        } else {
            append(w)
        }
        if (i < words.size - 1) append(' ')
    }
}

/**
 * A gift: wrapped for everyone, opened by the one it's for. Its sender sees
 * what's in it and can take it back until then.
 */
@Composable
private fun GiftCard(app: AppState, m: Message) {
    val g = m.gift ?: return
    val me = app.me
    val forMe = me != null && g.to?.id == me.id
    val mine = me != null && m.author?.id == me.id
    Surface(color = PanelHi, shape = RoundedCornerShape(10.dp), modifier = Modifier.padding(top = 4.dp)) {
        Row(Modifier.padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.CardGiftcard, "gift", tint = if (g.state == "sealed") Accent else TextDim)
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text("A gift for @${g.to?.handle ?: "someone"}", fontWeight = FontWeight.Bold)
                val inside = if (g.item != null) "${g.count} ${g.item}" else null
                Text(
                    when (g.state) {
                        "opened" -> if (inside != null) "Opened: $inside" else "Opened"
                        "returned" -> "Taken back"
                        else -> if (mine && inside != null) "Wrapped: $inside" else "Wrapped"
                    },
                    color = TextDim, fontSize = 13.sp,
                )
            }
            if (g.state == "sealed" && forMe) Button({ app.claim(m) }) { Text("Open") }
            if (g.state == "sealed" && mine) TextButton({ app.cancel(m) }) { Text("Take back") }
        }
    }
}

/** Typing a message, @mentions offered from the members, and the gift button. */
@Composable
private fun Composer(app: AppState, onGift: () -> Unit) {
    var text by remember { mutableStateOf("") }
    val partial = text.substringAfterLast(' ').takeIf { it.startsWith("@") }?.drop(1)
    val names = when (val p = app.place) {
        is Place.InServer -> app.members.filter { it.status == "member" }.map { it.person.handle }
        is Place.WithPerson -> listOf(p.handle)
        null -> emptyList()
    }.filter { it != app.me?.handle }
    if (partial != null) {
        val matches = names.filter { it.startsWith(partial, ignoreCase = true) }.take(8)
        LazyRow(Modifier.padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            items(matches) { h ->
                AssistChip(onClick = { text = text.dropLast(partial.length + 1) + "@$h " }, label = { Text("@$h") })
            }
        }
    }
    Row(Modifier.fillMaxWidth().background(Panel).padding(6.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onGift) { Icon(Icons.Filled.CardGiftcard, "send a gift", tint = Accent) }
        TextField(
            text, { text = it.take(2000) }, Modifier.weight(1f),
            placeholder = { Text("Message") },
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
            colors = TextFieldDefaults.colors(focusedContainerColor = PanelHi, unfocusedContainerColor = PanelHi),
            shape = RoundedCornerShape(20.dp),
            maxLines = 5,
        )
        IconButton({
            if (text.isNotBlank()) {
                app.post(text.trim())
                text = ""
            }
        }) { Icon(Icons.AutoMirrored.Filled.Send, "send", tint = Accent) }
    }
}

/**
 * Send items from the bag to someone, as a message everyone here sees and
 * only they can open.
 */
@Composable
fun GiftDialog(app: AppState, presetItem: String? = null, close: () -> Unit) {
    val have = app.bag.filterNotNull().groupBy { it.item }.mapValues { (_, v) -> v.sumOf { it.count } }
    var item by remember { mutableStateOf(presetItem ?: have.keys.firstOrNull()) }
    var count by remember { mutableStateOf(1) }
    val people = when (val p = app.place) {
        is Place.InServer -> app.members.filter { it.status == "member" && it.person.id != app.me?.id }.map { it.person.handle }
        is Place.WithPerson -> listOf(p.handle)
        null -> emptyList()
    }
    var to by remember { mutableStateOf(people.firstOrNull()) }
    var note by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = close,
        title = { Text("Send a gift") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text("What", color = TextDim)
                ChipFlow(have.keys.toList(), item, label = { "$it ×${have[it]}" }) { item = it; count = 1 }
                val max = have[item] ?: 0
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton({ if (count > 1) count-- }) { Text("−") }
                    Text("$count of $max")
                    TextButton({ if (count < max) count++ }) { Text("+") }
                }
                Text("For", color = TextDim)
                if (people.isEmpty()) Text("No one else here yet.", color = TextDim)
                ChipFlow(people, to, label = { "@$it" }) { to = it }
                TextField(note, { note = it.take(200) }, placeholder = { Text("a note (optional)") })
                Text("Everyone here sees it wrapped; only they can open it.", color = TextDim, fontSize = 12.sp)
            }
        },
        confirmButton = {
            Button(
                {
                    val i = item
                    val t = to
                    if (i != null && t != null) {
                        app.post(("@$t " + note).trim(), i, count, t)
                        close()
                    }
                },
                enabled = item != null && to != null && count > 0,
            ) { Text("Send") }
        },
        dismissButton = { TextButton(close) { Text("Cancel") } },
    )
}

/** Choices as chips, wrapping onto rows of three. */
@Composable
fun <T> ChipFlow(options: List<T>, selected: T?, label: (T) -> String, pick: (T) -> Unit) {
    Column {
        options.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                row.forEach { o ->
                    val on = o == selected
                    Surface(
                        onClick = { pick(o) },
                        shape = RoundedCornerShape(14.dp),
                        color = if (on) Accent else PanelHi,
                        modifier = Modifier.padding(vertical = 3.dp),
                    ) {
                        Text(label(o), color = if (on) Night else TextMain, modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp), fontSize = 13.sp)
                    }
                }
            }
        }
    }
}

fun serverFor(app: AppState): Server? = (app.place as? Place.InServer)?.let { app.server(it.id) }

@Composable
fun Dot(color: Color) {
    Box(Modifier.size(8.dp).clip(CircleShape).background(color))
}
