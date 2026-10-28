package app.sosh.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.sosh.AppState
import app.sosh.Place
import app.sosh.data.Member
import app.sosh.data.Server

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Page(title: String, back: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = { IconButton(back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "back") } },
                title = { Text(title) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Panel),
            )
        },
        containerColor = Night,
    ) { pad -> Column(Modifier.fillMaxSize().padding(pad)) { content() } }
}

/** Every server: enter the ones we're in, ask to join the rest. */
@Composable
fun ExploreScreen(app: AppState, back: () -> Unit) = Page("Servers", back) {
    LaunchedEffect(Unit) { app.refreshServers() }
    LazyColumn(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items(app.servers, key = { it.id }) { s ->
            Surface(color = Panel, shape = RoundedCornerShape(12.dp)) {
                Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(s.name, fontWeight = FontWeight.Bold)
                        Text(s.description, color = TextDim, fontSize = 13.sp)
                        Text(
                            "${s.members} members · " + when (s.policy) {
                                "open" -> "anyone can join"
                                "friends" -> "the owner's friends join, others ask"
                                else -> "join by approval"
                            },
                            color = TextDim, fontSize = 12.sp,
                        )
                    }
                    when (s.status) {
                        "member" -> Button({ app.open(Place.InServer(s.id)); back() }) { Text("Open") }
                        "pending" -> Text("asked", color = TextDim)
                        "banned" -> Text("banned", color = Bad)
                        "invited" -> Button({ app.join(s) }) { Text("Accept") }
                        else -> OutlinedButton({ app.join(s) }) { Text(if (s.policy == "open") "Join" else "Ask") }
                    }
                }
            }
        }
    }
}

@Composable
fun FriendsScreen(app: AppState, back: () -> Unit, dm: (String) -> Unit) = Page("Friends", back) {
    var handle by remember { mutableStateOf("") }
    LaunchedEffect(Unit) { app.refreshFriends() }
    Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
        OutlinedTextField(
            handle, { handle = it.filter { c -> c.isLetterOrDigit() || c == '_' || c == '@' }.take(17) },
            Modifier.weight(1f), label = { Text("add by handle") }, singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
        )
        Spacer(Modifier.width(8.dp))
        Button({ if (handle.isNotBlank()) { app.addFriend(handle); handle = "" } }) { Text("Add") }
    }
    val f = app.friends
    LazyColumn(Modifier.padding(horizontal = 12.dp)) {
        if (f.incoming.isNotEmpty()) item { Section("Asking you") }
        items(f.incoming) { p ->
            PersonRow(p.handle) {
                TextButton({ app.acceptFriend(p.handle) }) { Text("Accept") }
                TextButton({ app.removeFriend(p.handle) }) { Text("Decline", color = Bad) }
            }
        }
        item { Section("Friends") }
        if (f.friends.isEmpty()) item { Text("No one yet: add someone by their handle.", color = TextDim) }
        items(f.friends) { p ->
            PersonRow(p.handle) {
                TextButton({ dm(p.handle) }) { Text("Message") }
                TextButton({ app.removeFriend(p.handle) }) { Text("Remove", color = TextDim) }
            }
        }
        if (f.outgoing.isNotEmpty()) item { Section("You asked") }
        items(f.outgoing) { p ->
            PersonRow(p.handle) { TextButton({ app.removeFriend(p.handle) }) { Text("Withdraw", color = TextDim) } }
        }
    }
}

@Composable
private fun Section(title: String) {
    Text(title, color = TextDim, fontSize = 13.sp, modifier = Modifier.padding(top = 16.dp, bottom = 4.dp))
}

@Composable
private fun PersonRow(handle: String, actions: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text("@$handle", color = handleColor(handle), modifier = Modifier.weight(1f))
        actions()
    }
}

/**
 * The bag. Tap something to send it to someone: in the chat that's open
 * (everyone sees the gift, only they can open it) or straight to a friend.
 */
@Composable
fun BagScreen(app: AppState, back: () -> Unit) = Page("Bag", back) {
    var picked by remember { mutableStateOf<String?>(null) }
    var toFriend by remember { mutableStateOf<String?>(null) }
    Text(
        "Tap something to send it to someone. They open it from the chat.",
        color = TextDim, fontSize = 13.sp, modifier = Modifier.padding(12.dp),
    )
    LazyVerticalGrid(GridCells.Fixed(4), Modifier.padding(horizontal = 12.dp)) {
        itemsIndexed(app.bag) { _, slot ->
            Surface(
                onClick = { if (slot != null) picked = slot.item },
                color = if (slot != null) PanelHi else Panel,
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.padding(4.dp).aspectRatio(1f),
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                    if (slot != null) {
                        Text(slot.item, fontSize = 12.sp)
                        Text("×${slot.count}", color = TextDim, fontSize = 12.sp)
                    }
                }
            }
        }
    }
    picked?.let { item ->
        AlertDialog(
            onDismissRequest = { picked = null },
            title = { Text("Send $item") },
            text = {
                Column {
                    val here = app.place
                    if (here != null) {
                        Text("In the chat that's open:", color = TextDim)
                        TextButton({ toFriend = null; picked = null; giftHere = item }) {
                            Text(
                                when (here) {
                                    is Place.InServer -> "${app.server(here.id)?.name ?: "this server"} (pick who)"
                                    is Place.WithPerson -> "@${here.handle}"
                                }
                            )
                        }
                    }
                    Text("Or straight to a friend:", color = TextDim)
                    if (app.friends.friends.isEmpty()) Text("No friends yet.", color = TextDim)
                    app.friends.friends.forEach { f ->
                        TextButton({ toFriend = f.handle }) { Text("@${f.handle}") }
                    }
                }
            },
            confirmButton = { TextButton({ picked = null }) { Text("Cancel") } },
        )
    }
    toFriend?.let { handle ->
        val item = picked ?: return@let
        CountDialog(app, item, "@$handle", { toFriend = null; picked = null }) { n ->
            app.giftDirect(handle, item, n, "@$handle")
            toFriend = null
            picked = null
        }
    }
    giftHere?.let { item -> GiftDialog(app, item) { giftHere = null; back() } }
}

// which item the bag is sending into the open chat (GiftDialog takes over)
private var giftHere by mutableStateOf<String?>(null)

@Composable
private fun CountDialog(app: AppState, item: String, to: String, close: () -> Unit, send: (Int) -> Unit) {
    val max = app.bag.filterNotNull().filter { it.item == item }.sumOf { it.count }
    var n by remember { mutableStateOf(1) }
    AlertDialog(
        onDismissRequest = close,
        title = { Text("$item for $to") },
        text = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton({ if (n > 1) n-- }) { Text("−") }
                Text("$n of $max")
                TextButton({ if (n < max) n++ }) { Text("+") }
            }
        },
        confirmButton = { Button({ send(n) }, enabled = n in 1..max) { Text("Send") } },
        dismissButton = { TextButton(close) { Text("Cancel") } },
    )
}

/**
 * A server's members, and those waiting to get in for whoever may let
 * them. Tap someone to act on them, as far as your role allows.
 */
@Composable
fun MembersScreen(app: AppState, back: () -> Unit) {
    val s = serverFor(app) ?: run { back(); return }
    LaunchedEffect(s.id) { app.loadMembers() }
    var acting by remember { mutableStateOf<Member?>(null) }
    var inviting by remember { mutableStateOf(false) }
    var settings by remember { mutableStateOf(false) }
    Page("${s.name}: members", back) {
        Row(Modifier.padding(horizontal = 12.dp)) {
            if (s.can("invite")) TextButton({ inviting = true }) { Text("Invite") }
            if (s.can("manage_server")) TextButton({ settings = true }) { Text("Settings") }
            Spacer(Modifier.weight(1f))
            if (s.role != "owner") TextButton({ app.leave(s); back() }) { Text("Leave", color = Bad) }
        }
        LazyColumn(Modifier.padding(horizontal = 12.dp)) {
            val groups = app.members.groupBy { it.status }
            for ((status, title) in listOf("pending" to "Waiting to get in", "invited" to "Invited", "member" to "Members", "banned" to "Banned")) {
                val list = groups[status] ?: continue
                item { Section("$title — ${list.size}") }
                items(list, key = { it.person.id }) { m ->
                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("@${m.person.handle}", color = handleColor(m.person.handle), modifier = Modifier.weight(1f))
                        if (m.role != "member") Text(m.role, color = Accent, fontSize = 12.sp)
                        if (m.person.id != app.me?.id) TextButton({ acting = m }) { Text("…") }
                    }
                }
            }
        }
    }
    acting?.let { m -> MemberActions(app, s, m) { acting = null } }
    if (inviting) HandleDialog("Invite to ${s.name}", { inviting = false }) { app.invite(s, it); inviting = false }
    if (settings) ServerSettings(app, s) { settings = false }
}

@Composable
private fun MemberActions(app: AppState, s: Server, m: Member, close: () -> Unit) {
    val h = m.person.handle
    AlertDialog(
        onDismissRequest = close,
        title = { Text("@$h") },
        text = {
            Column {
                Text("${m.status}, ${m.role}", color = TextDim)
                if (m.status == "pending" && s.can("approve")) {
                    TextButton({ app.memberAction(s, h, "approve"); close() }) { Text("Let them in") }
                    TextButton({ app.memberAction(s, h, "reject"); close() }) { Text("Turn down") }
                }
                if (m.status == "member" && s.can("set_roles")) {
                    val ranks = listOf("member", "moderator", "admin")
                    val mine = listOf("member", "moderator", "admin", "owner").indexOf(s.role)
                    ranks.filterIndexed { i, r -> i < mine && r != m.role }.forEach { r ->
                        TextButton({ app.memberAction(s, h, "role", r); close() }) { Text("Make $r") }
                    }
                }
                if (m.status == "member" && s.can("kick")) TextButton({ app.memberAction(s, h, "kick"); close() }) { Text("Kick", color = Bad) }
                if (m.status != "banned" && s.can("ban")) TextButton({ app.memberAction(s, h, "ban"); close() }) { Text("Ban", color = Bad) }
                if (m.status == "banned" && s.can("ban")) TextButton({ app.memberAction(s, h, "unban"); close() }) { Text("Unban") }
                HorizontalDivider()
                TextButton({ app.addFriend(h); close() }) { Text("Add friend") }
            }
        },
        confirmButton = { TextButton(close) { Text("Close") } },
    )
}

@Composable
fun HandleDialog(title: String, close: () -> Unit, done: (String) -> Unit) {
    var h by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = close,
        title = { Text(title) },
        text = { OutlinedTextField(h, { h = it.removePrefix("@").take(16) }, label = { Text("handle") }, singleLine = true) },
        confirmButton = { Button({ if (h.isNotBlank()) done(h) }) { Text("OK") } },
        dismissButton = { TextButton(close) { Text("Cancel") } },
    )
}

@Composable
private fun ServerSettings(app: AppState, s: Server, close: () -> Unit) {
    var name by remember { mutableStateOf(s.name) }
    var about by remember { mutableStateOf(s.description) }
    var policy by remember { mutableStateOf(s.policy) }
    AlertDialog(
        onDismissRequest = close,
        title = { Text("Server settings") },
        text = {
            Column {
                OutlinedTextField(name, { name = it.take(32) }, label = { Text("name") }, singleLine = true)
                OutlinedTextField(about, { about = it.take(200) }, label = { Text("description") })
                Spacer(Modifier.height(8.dp))
                Text("Who gets in", color = TextDim)
                ChipFlow(listOf("open", "friends", "approval"), policy, label = { it }) { policy = it }
                Text(
                    when (policy) {
                        "open" -> "Anyone who asks is in."
                        "friends" -> "Your friends are in straight away; anyone else waits for approval."
                        else -> "Everyone waits for a moderator to let them in."
                    },
                    color = TextDim, fontSize = 12.sp,
                )
            }
        },
        confirmButton = { Button({ app.updateServer(s, name, about, policy); close() }) { Text("Save") } },
        dismissButton = { TextButton(close) { Text("Cancel") } },
    )
}

@Composable
fun Centered(text: String) {
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(text, color = TextDim, style = MaterialTheme.typography.bodyLarge)
    }
}
