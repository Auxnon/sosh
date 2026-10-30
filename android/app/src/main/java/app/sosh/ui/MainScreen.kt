package app.sosh.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Backpack
import androidx.compose.material.icons.filled.CardGiftcard
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.Face
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.Mail
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.VerticalSplit
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDrawerState
import androidx.compose.material3.rememberModalBottomSheetState
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
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Constraints
import kotlin.math.roundToInt
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
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
 * The app once signed in: a drawer with the server rail (Discord style),
 * and the open place: a server's chat and world, or a conversation. The
 * pockets can be dragged from anywhere onto the chat, which wraps what's
 * dragged as a present.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ChatScreen(app: AppState, go: (Screen) -> Unit) {
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    var gift by remember { mutableStateOf<String?>(null) }
    var giftOpen by remember { mutableStateOf(false) }
    val drag = remember { PocketDrag() }
    drag.onDrop = { from, to ->
        when (to) {
            is PocketDrag.Target.Pocket -> app.bagSwap(from, to.i)
            PocketDrag.Target.Chat -> app.bag.getOrNull(from)?.let { gift = it.item; giftOpen = true }
        }
    }
    var origin by remember { mutableStateOf(Offset.Zero) }
    BackHandler(enabled = app.place is Place.InServer && app.pane != Pane.Chat) { app.pane = Pane.Chat }

    ModalNavigationDrawer(
        drawerState = drawer,
        drawerContent = {
            ModalDrawerSheet(
                drawerContainerColor = Color.Transparent, drawerShape = RectangleShape,
                modifier = Modifier.width(340.dp), windowInsets = WindowInsets(0),
            ) {
                Drawer(app, go) { scope.launch { drawer.close() } }
            }
        },
    ) {
        Box(Modifier.fillMaxSize().ground().onGloballyPositioned { origin = it.positionInRoot() }) {
            Column(
                Modifier.fillMaxSize().systemBarsPadding().imePadding().padding(start = 10.dp, end = 10.dp, top = 8.dp, bottom = 12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Header(app, { scope.launch { drawer.open() } }, go)
                when (val p = app.place) {
                    null -> Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                        Text("Pick a server or a friend from the menu.", color = TextDim)
                    }
                    is Place.InServer -> {
                        ServerView(app, p.id, drag, Modifier.weight(1f))
                        Tray(app, drag, panes = !WindowInsets.isImeVisible) { gift = null; giftOpen = true }
                    }
                    is Place.WithPerson -> {
                        Messages(app, drag, Modifier.weight(1f))
                        Tray(app, drag, panes = false) { gift = null; giftOpen = true }
                    }
                }
            }
            DragGhost(app.bag, drag, origin)
        }
    }
    if (giftOpen) GiftSheet(app, gift) { giftOpen = false }
}

/** The plastic bar on top: the menu, where we are, its members. */
@Composable
private fun Header(app: AppState, openDrawer: () -> Unit, go: (Screen) -> Unit) {
    Row(
        Modifier.fillMaxWidth().height(60.dp).plastic().padding(horizontal = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        IconPlastic(Icons.Filled.Menu, "servers", onClick = openDrawer)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            when (val p = app.place) {
                is Place.InServer -> {
                    val s = app.server(p.id)
                    Text(s?.name ?: "server", color = TextMain, fontSize = 20.sp, fontWeight = FontWeight.ExtraBold, lineHeight = 20.sp)
                    Label(
                        if (!app.online) "connecting..."
                        else "universe ${s?.universe?.first ?: 0},${s?.universe?.second ?: 0} · ${s?.members ?: 0} members",
                    )
                }
                is Place.WithPerson -> {
                    NameTag(p.handle, tilt = 0f, size = 16)
                    Label("direct messages")
                }
                null -> Text("sosh", color = Paper, fontSize = 20.sp, fontWeight = FontWeight.ExtraBold)
            }
        }
        if (app.place is Place.InServer) IconPlastic(Icons.Filled.Group, "members") { go(Screen.Members) }
    }
}

@Composable
private fun IconPlastic(icon: ImageVector, label: String, tone: Tone = Tone.Plastic, onClick: () -> Unit) {
    PlasticButton(onClick, Modifier.size(46.dp), tone = tone, shape = RoundedCornerShape(16.dp)) {
        Icon(icon, label, Modifier.size(22.dp))
    }
}

/**
 * A server: its chat, its world, or both. The world slides down over the
 * chat (in from the side, with the phone on its side) and back out. Once
 * opened it stays loaded, only paused while it's away, until we leave
 * the server. Its backpack opens the pockets over it.
 */
@Composable
private fun ServerView(app: AppState, serverId: Long, drag: PocketDrag, modifier: Modifier) {
    var started by remember(serverId) { mutableStateOf(false) }
    var pockets by remember(serverId) { mutableStateOf(false) }
    LaunchedEffect(serverId, app.pane) {
        if (app.pane != Pane.Chat) started = true else pockets = false
    }
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
        val frame = RoundedCornerShape(24.dp)
        val shown = share > 0.01f
        val gap = with(LocalDensity.current) { if (shown && share < 0.99f) 10.dp.roundToPx() else 0 }
        // One layout whichever way round, so turning the phone or opening the
        // keyboard only resizes the world: in a Row/Column swap its web view
        // would be made again, and the game would load and sign in again.
        Layout(
            content = {
                Box(if (shown) Modifier.clip(frame).border(3.dp, Edge, frame) else Modifier) {
                    if (started) {
                        key(serverId) { WorldPane(app, serverId, app.pane != Pane.Chat, Modifier.fillMaxSize()) }
                        if (shown) {
                            if (app.pane == Pane.World && share == 1f && !pockets) {
                                Overlay(app, Modifier.align(Alignment.BottomStart).padding(start = 10.dp, bottom = 10.dp, end = 76.dp))
                            }
                            BackpackButton(app.bag.count { it != null }, { pockets = true }, Modifier.align(Alignment.BottomEnd).padding(10.dp))
                            PocketsPanel(app.bag, drag, pockets, { pockets = false }, Modifier.align(Alignment.BottomCenter))
                        }
                    }
                }
                if (share < 1f) Messages(app, drag, Modifier)
            },
            modifier = Modifier.fillMaxSize(),
        ) { parts, c ->
            val across = if (wide) c.maxWidth else c.maxHeight
            val worldSize = (across * share).roundToInt()
            val rest = (across - worldSize - gap).coerceAtLeast(0)
            fun fixed(along: Int) =
                if (wide) Constraints.fixed(along, c.maxHeight) else Constraints.fixed(c.maxWidth, along)
            val world = parts[0].measure(fixed(worldSize))
            val chat = parts.getOrNull(1)?.measure(fixed(rest))
            layout(c.maxWidth, c.maxHeight) {
                world.place(0, 0)
                chat?.place(if (wide) worldSize + gap else 0, if (wide) 0 else worldSize + gap)
            }
        }
    }
}

/**
 * All world: the latest few lines over it on paper, as the game's own chat
 * log was. Tapping them brings the chat back beside it.
 */
@Composable
private fun Overlay(app: AppState, modifier: Modifier) {
    Column(
        modifier.fillMaxWidth().paper(RoundedCornerShape(18.dp), edge = Color(0x661A1540)).clip(RoundedCornerShape(18.dp))
            .clickable { app.pane = Pane.Both }.padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        for (m in app.messages.takeLast(3)) {
            val who = m.author?.handle ?: "someone"
            val line = buildAnnotatedString {
                withStyle(SpanStyle(color = handleInk(who), fontWeight = FontWeight.ExtraBold)) { append(who) }
                append("  ")
                val g = m.gift
                if (g != null) append("a present for ${g.to?.handle ?: "someone"}") else append(mentions(m.body, app.me?.handle))
            }
            Text(line, color = Ink, fontSize = 13.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Label("tap for chat", color = InkFaint)
    }
}

/** Typing, the present button, and (in a server) Chat / Both / World. */
@Composable
private fun Tray(app: AppState, drag: PocketDrag, panes: Boolean, onGift: () -> Unit) {
    val over = drag.over == PocketDrag.Target.Chat
    val shape = RoundedCornerShape(24.dp)
    Column(
        Modifier.fillMaxWidth().chatTarget(drag, "tray").plastic(shape)
            .then(if (over) Modifier.border(3.dp, Good, shape) else Modifier).padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Composer(app, onGift)
        if (panes) PaneBar(app)
    }
}

/** Chat, both, or the world: one tap between them. */
@Composable
private fun PaneBar(app: AppState) {
    val options = listOf(
        Triple(Pane.Chat, "chat", Icons.Filled.ChatBubble),
        Triple(Pane.Both, "both", Icons.Filled.VerticalSplit),
        Triple(Pane.World, "world", Icons.Filled.Public),
    )
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for ((pane, label, icon) in options) {
            val on = app.pane == pane
            PlasticButton(
                { app.pane = pane }, Modifier.weight(1f).height(46.dp),
                tone = if (on) Tone.Green else Tone.Plastic, shape = RoundedCornerShape(16.dp),
            ) {
                Icon(icon, null, Modifier.size(18.dp))
                Text(label.uppercase(), style = TechLabel.copy(fontSize = 11.sp))
            }
        }
    }
}

/** The rail of servers (memory-card slots) and shortcuts, and the page beside it. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Drawer(app: AppState, go: (Screen) -> Unit, close: () -> Unit) {
    var dms by remember { mutableStateOf(app.place is Place.WithPerson) }
    Row(
        Modifier.fillMaxHeight().systemBarsPadding().padding(start = 10.dp, top = 8.dp, bottom = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Column(
            Modifier.width(68.dp).fillMaxHeight().plastic(RoundedCornerShape(24.dp)).padding(vertical = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            IconPlastic(Icons.Filled.Mail, "direct messages", if (dms) Tone.Green else Tone.Plastic) { dms = true }
            Label("slots", style = TechLabel.copy(fontSize = 8.sp))
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                for (s in app.servers.filter { it.isMember }) {
                    MemorySlot(s, !dms && app.place == Place.InServer(s.id)) {
                        dms = false
                        app.open(Place.InServer(s.id))
                        close()
                    }
                }
                Box(
                    Modifier.size(48.dp).clip(RoundedCornerShape(16.dp))
                        .drawBehind {
                            drawRoundRect(
                                Color(0xFF8B82D8), cornerRadius = CornerRadius(16.dp.toPx()),
                                style = Stroke(2.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 8f))),
                            )
                        }
                        .clickable { go(Screen.Explore); close() },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.Add, "find servers", tint = Color(0xFF9FE38A)) }
            }
            RailIcon(Icons.Filled.People, "friends") { go(Screen.Friends); close() }
            RailIcon(Icons.Filled.Backpack, "pockets") { go(Screen.Bag); close() }
            RailIcon(Icons.Filled.Face, "your look") { go(Screen.Creator); close() }
        }
        Column(Modifier.width(252.dp).fillMaxHeight().paper(RoundedCornerShape(24.dp)).clip(RoundedCornerShape(24.dp))) {
            val me = app.me
            if (dms) {
                Column(Modifier.padding(18.dp, 18.dp, 18.dp, 6.dp)) {
                    Label("conversations", color = InkFaint)
                    Text("Direct messages", color = Ink, fontSize = 22.sp, fontWeight = FontWeight.ExtraBold)
                }
                LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 18.dp, vertical = 8.dp)) {
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
                    IslandBanner(Modifier.fillMaxWidth().height(116.dp))
                    Column(Modifier.padding(18.dp, 14.dp, 18.dp, 6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Label("universe ${s.universe.first},${s.universe.second} · ${s.policy} · ${s.role ?: "member"}", color = InkFaint)
                        Text(s.name, color = Ink, fontSize = 24.sp, fontWeight = FontWeight.ExtraBold)
                        if (s.description.isNotEmpty()) Text(s.description, color = InkDim, fontSize = 13.sp, lineHeight = 19.sp)
                    }
                    Column(Modifier.padding(horizontal = 18.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        PlasticButton({ app.pane = Pane.World; close() }, Modifier.fillMaxWidth().height(48.dp), tone = Tone.Orange) {
                            Text("Enter the world", fontWeight = FontWeight.ExtraBold, fontSize = 15.sp)
                        }
                        PaperButton("Members", { go(Screen.Members); close() }, Modifier.fillMaxWidth().height(48.dp))
                    }
                    val people = app.members.filter { it.status == "member" }.take(12)
                    if (people.isNotEmpty()) {
                        Label("members", Modifier.padding(start = 18.dp, top = 10.dp, bottom = 8.dp), color = InkFaint)
                        FlowRow(
                            Modifier.padding(horizontal = 18.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) { people.forEach { NameTag(it.person.handle, tilt = 0f) } }
                    }
                } else {
                    Column(Modifier.padding(18.dp)) {
                        Text("Servers", color = Ink, fontSize = 22.sp, fontWeight = FontWeight.ExtraBold)
                        Text("Pick one from the rail, or + to find more.", color = InkDim, fontSize = 13.sp)
                    }
                }
                Spacer(Modifier.weight(1f))
            }
            if (me != null) {
                Row(
                    Modifier.fillMaxWidth().drawBehind {
                        drawLine(
                            Color(0xFFE3CC98), Offset(0f, 0f), Offset(size.width, 0f), 2.dp.toPx(),
                            pathEffect = PathEffect.dashPathEffect(floatArrayOf(12f, 8f)),
                        )
                    }.padding(start = 18.dp, end = 8.dp, top = 6.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(me.handle, color = handleInk(me.handle), fontWeight = FontWeight.ExtraBold, modifier = Modifier.weight(1f))
                    TextButton({ app.logout() }) { Text("Sign out", color = InkLink, fontWeight = FontWeight.Bold) }
                }
            }
        }
    }
}

/** A server as a memory card: its colour, its initials; the open one is ringed. */
@Composable
private fun MemorySlot(s: Server, on: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(10.dp, 10.dp, 16.dp, 16.dp)
    Column(
        Modifier.size(48.dp, 56.dp)
            .then(if (on) Modifier.border(3.dp, TextMain, shape) else Modifier)
            .plastic(shape, handleColor(s.name), Edge, drop = 3.dp, shine = 0.45f)
            .clip(shape).clickable(onClickLabel = s.name, onClick = onClick).padding(bottom = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp, Alignment.Bottom),
    ) {
        Box(Modifier.size(30.dp, 6.dp).background(Color(0x4D1A1540), RoundedCornerShape(3.dp)))
        Text(initials(s.name), color = Color(0xFF2A1F14), fontWeight = FontWeight.ExtraBold, fontSize = 16.sp)
    }
}

@Composable
private fun RailIcon(icon: ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.size(48.dp).clip(RoundedCornerShape(24.dp)).clickable(onClickLabel = label, onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, label, tint = TextDim)
    }
}

/** A small floating island over the sea, for a server's page. */
@Composable
private fun IslandBanner(modifier: Modifier) {
    Canvas(modifier) {
        val u = size.width / 252f
        drawRect(Color(0xFF8FC9F0))
        drawRect(Color(0xFF4A8FD0), Offset(0f, size.height * 0.76f), Size(size.width, size.height * 0.24f))
        drawOval(Color(0xCCFFFFFF), Offset(176 * u, 9 * u), Size(48 * u, 14 * u))
        val under = Path().apply {
            moveTo(30 * u, 62 * u); lineTo(150 * u, 62 * u); lineTo(128 * u, 88 * u); lineTo(74 * u, 94 * u); close()
            moveTo(178 * u, 40 * u); lineTo(238 * u, 40 * u); lineTo(224 * u, 60 * u); lineTo(194 * u, 64 * u); close()
        }
        drawPath(under, Color(0xFFB07A45))
        drawRoundRect(Color(0xFF7CCB5A), Offset(26 * u, 50 * u), Size(128 * u, 16 * u), CornerRadius(8 * u))
        drawRoundRect(Color(0xFF7CCB5A), Offset(174 * u, 30 * u), Size(68 * u, 13 * u), CornerRadius(6 * u))
        drawRect(Color(0xFF7A5230), Offset(52 * u, 40 * u), Size(5 * u, 12 * u))
        drawCircle(Color(0xFF4FA83A), 12 * u, Offset(54 * u, 38 * u))
    }
}

@Composable
private fun DmRow(handle: String, last: String?, onClick: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).clickable(onClick = onClick).padding(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        NameTag(handle, tilt = 0f)
        if (!last.isNullOrEmpty()) Text(last, color = InkDim, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

fun initials(name: String): String =
    name.split(' ').filter { it.isNotEmpty() }.let { w ->
        if (w.size >= 2) w.take(2).joinToString("") { it.take(1).uppercase() } else name.take(2).replaceFirstChar { it.uppercase() }
    }.ifEmpty { "?" }

/**
 * The chat as speech bubbles on paper, each with its speaker's name tag.
 * While something's dragged out of the pockets, it says it can be dropped.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun Messages(app: AppState, drag: PocketDrag, modifier: Modifier) {
    val list = rememberLazyListState()
    val n = app.messages.size
    LaunchedEffect(n) { if (n > 0) list.animateScrollToItem(n - 1) }
    var menuFor by remember { mutableStateOf<Message?>(null) }
    val shape = RoundedCornerShape(22.dp)
    val over = drag.over == PocketDrag.Target.Chat
    Box(modifier.fillMaxWidth().chatTarget(drag, "messages").then(if (over) Modifier.border(3.dp, Good, shape) else Modifier)) {
        LazyColumn(
            Modifier.fillMaxSize(), state = list,
            contentPadding = PaddingValues(start = 4.dp, end = 4.dp, top = 16.dp, bottom = 6.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp, Alignment.Bottom),
        ) {
            item {
                if (n >= 50) TextButton({ app.loadOlder() }) { Text(if (app.loadingOlder) "loading..." else "Older messages", color = TextDim) }
            }
            items(app.messages, key = { it.id }) { m -> Bubble(app, m) { menuFor = m } }
        }
        if (drag.from != null) {
            Text(
                "DROP IN THE CHAT TO WRAP A PRESENT", style = TechLabel.copy(fontSize = 10.sp), color = TextMain,
                modifier = Modifier.align(Alignment.TopCenter).padding(6.dp).fillMaxWidth()
                    .background(Color(0xE0241E4E), RoundedCornerShape(18.dp))
                    .border(2.dp, if (over) Color(0xFF9FE38A) else Color(0xFF8B82D8), RoundedCornerShape(18.dp))
                    .padding(12.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
        }
    }
    menuFor?.let { m ->
        val mine = m.author?.id == app.me?.id
        val mod = (app.place as? Place.InServer)?.let { app.server(it.id)?.can("manage_messages") } == true
        AlertDialog(
            onDismissRequest = { menuFor = null },
            containerColor = Paper, titleContentColor = Ink, textContentColor = InkDim,
            title = { Text("Message") },
            text = { Text(m.body.ifEmpty { "(a present)" }) },
            confirmButton = {
                if (mine || mod) TextButton({ app.deleteMessage(m); menuFor = null }) { Text("Delete", color = Color(0xFFC2413A)) }
            },
            dismissButton = { TextButton({ menuFor = null }) { Text("Close", color = InkLink) } },
        )
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun Bubble(app: AppState, m: Message, onMenu: () -> Unit) {
    val who = m.author?.handle ?: "someone"
    Box(Modifier.fillMaxWidth()) {
        Column(
            Modifier.fillMaxWidth().paper().clip(RoundedCornerShape(22.dp))
                .combinedClickable(onClick = {}, onLongClick = onMenu)
                .padding(start = 16.dp, end = 16.dp, top = 18.dp, bottom = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (m.body.isNotEmpty()) Text(mentions(m.body, app.me?.handle), color = Ink, fontSize = 15.sp, lineHeight = 21.sp)
            if (m.gift != null) PresentCard(app, m)
        }
        NameTag(who, Modifier.offset(14.dp, (-12).dp))
        Label(m.at.drop(11).take(5), Modifier.align(Alignment.TopEnd).padding(top = 8.dp, end = 14.dp), color = InkFaint)
    }
}

/** @handles highlighted, ours most of all. */
fun mentions(body: String, me: String?) = buildAnnotatedString {
    val words = body.split(' ')
    words.forEachIndexed { i, w ->
        if (w.startsWith("@") && w.length > 1) {
            val isMe = me != null && w.drop(1).trimEnd(',', '.', '!', '?', ':').equals(me, ignoreCase = true)
            withStyle(SpanStyle(color = if (isMe) OnAccent else InkLink, background = if (isMe) Accent else Color.Transparent, fontWeight = FontWeight.ExtraBold)) {
                append(w)
            }
        } else {
            append(w)
        }
        if (i < words.size - 1) append(' ')
    }
}

/**
 * A present: wrapped for everyone, opened by the one it's for. Its sender
 * sees what's in it and can take it back until then.
 */
@Composable
private fun PresentCard(app: AppState, m: Message) {
    val g = m.gift ?: return
    val me = app.me
    val forMe = me != null && g.to?.id == me.id
    val mine = me != null && m.author?.id == me.id
    Row(
        Modifier.fillMaxWidth().background(PaperDeep, RoundedCornerShape(18.dp)).drawBehind {
            drawRoundRect(
                PaperEdge, cornerRadius = CornerRadius(18.dp.toPx()),
                style = Stroke(2.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 8f))),
            )
        }.padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Present(if (g.state == "sealed") 1f else 0.45f)
        Column(Modifier.weight(1f)) {
            Text("A present for ${g.to?.handle ?: "someone"}", color = Ink, fontWeight = FontWeight.ExtraBold, fontSize = 15.sp)
            val inside = if (g.item != null) "${g.count} ${g.item}" else null
            Text(
                when (g.state) {
                    "opened" -> if (inside != null) "opened: $inside" else "opened"
                    "returned" -> "taken back"
                    else -> if (mine && inside != null) "wrapped: $inside" else "still wrapped"
                },
                color = InkDim, fontSize = 12.sp,
            )
        }
        if (g.state == "sealed" && forMe) {
            PlasticButton({ app.claim(m) }, tone = Tone.Orange) { Text("Open", fontWeight = FontWeight.ExtraBold) }
        }
        if (g.state == "sealed" && mine) TextButton({ app.cancel(m) }) { Text("Take back", color = InkLink, fontWeight = FontWeight.Bold) }
    }
}

/** A wrapped box with a ribbon. */
@Composable
fun Present(alpha: Float = 1f, size: androidx.compose.ui.unit.Dp = 38.dp) {
    Canvas(Modifier.size(size)) {
        val u = this.size.width / 40f
        drawRoundRect(Color(0xFF5DBB46).copy(alpha = alpha), Offset(6 * u, 14 * u), Size(28 * u, 22 * u), CornerRadius(4 * u))
        drawRoundRect(Color(0xFF7CCB5A).copy(alpha = alpha), Offset(4 * u, 10 * u), Size(32 * u, 8 * u), CornerRadius(3 * u))
        drawRect(Accent.copy(alpha = alpha), Offset(17 * u, 10 * u), Size(6 * u, 26 * u))
        drawOval(Accent.copy(alpha = alpha), Offset(9 * u, 3 * u), Size(11 * u, 8 * u))
        drawOval(Accent.copy(alpha = alpha), Offset(20 * u, 3 * u), Size(11 * u, 8 * u))
    }
}

/** Typing a message, @mentions offered from the members, and the present button. */
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
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(matches) { h ->
                NameTag(h, Modifier.clip(RoundedCornerShape(12.dp)).clickable { text = text.dropLast(partial.length + 1) + "@$h " }, tilt = 0f, size = 14)
            }
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        PlasticButton(onGift, Modifier.size(44.dp), shape = RoundedCornerShape(14.dp)) {
            Icon(Icons.Filled.CardGiftcard, "send a present", tint = Color(0xFFFFC566), modifier = Modifier.size(22.dp))
        }
        BasicTextField(
            text, { text = it.take(2000) }, Modifier.weight(1f),
            textStyle = TextStyle(color = Ink, fontSize = 15.sp, fontFamily = Rounded, fontWeight = FontWeight.Medium),
            cursorBrush = SolidColor(Ink),
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
            maxLines = 5,
            decorationBox = { field ->
                Box(
                    Modifier.fillMaxWidth().heightIn(min = 44.dp).background(Paper, RoundedCornerShape(16.dp)).padding(horizontal = 16.dp, vertical = 10.dp),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    if (text.isEmpty()) Text("Say something…", color = InkFaint, fontSize = 15.sp)
                    field()
                }
            },
        )
        PlasticButton(
            {
                if (text.isNotBlank()) {
                    app.post(text.trim())
                    text = ""
                }
            },
            Modifier.size(44.dp), tone = Tone.Orange, shape = RoundedCornerShape(14.dp),
        ) { Icon(Icons.AutoMirrored.Filled.Send, "send", Modifier.size(20.dp)) }
    }
}

/**
 * Wrap a present: items from the bag for someone, as a message everyone
 * here sees and only they can open. `presetItem` is what was dragged here.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun GiftSheet(app: AppState, presetItem: String? = null, close: () -> Unit) {
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
    val max = have[item] ?: 0
    ModalBottomSheet(
        onDismissRequest = close, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Paper, contentColor = Ink, scrimColor = Color(0x990E0B22),
    ) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 20.dp, end = 20.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Present()
                Column {
                    Text("Wrap a present", color = Ink, fontSize = 22.sp, fontWeight = FontWeight.ExtraBold)
                    Label("from your pockets", color = InkFaint)
                }
            }
            if (have.isEmpty()) Text("Your pockets are empty.", color = InkDim)
            FlowRow(
                Modifier.fillMaxWidth().background(PaperDeep, RoundedCornerShape(22.dp)).padding(12.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                for ((name, n) in have) {
                    val on = name == item
                    Box(
                        Modifier.size(52.dp).drawBehind {
                            val r = size.minDimension / 2
                            drawCircle(PaperEdge, r, center.copy(y = center.y + 3.dp.toPx()))
                            drawCircle(Paper, r)
                            if (on) drawCircle(Accent, r + 1.dp.toPx(), style = Stroke(3.dp.toPx()))
                        }.clip(androidx.compose.foundation.shape.CircleShape).clickable(onClickLabel = name) { item = name; count = 1 },
                        contentAlignment = Alignment.Center,
                    ) { ItemIcon(name, 28.dp) }
                }
            }
            if (item != null) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Column(Modifier.weight(1f)) {
                        Text(item!!, color = Ink, fontSize = 17.sp, fontWeight = FontWeight.ExtraBold)
                        Text("you have $max", color = InkDim, fontSize = 12.sp)
                    }
                    PaperButton("−", { if (count > 1) count-- })
                    Text("$count", color = Ink, fontSize = 20.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.width(40.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    PaperButton("+", { if (count < max) count++ })
                }
            }
            Label("for", color = InkFaint)
            if (people.isEmpty()) Text("No one else here yet.", color = InkDim)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                for (h in people) {
                    val on = h == to
                    NameTag(
                        h,
                        Modifier.then(if (on) Modifier.border(3.dp, Ink, RoundedCornerShape(12.dp)) else Modifier)
                            .clip(RoundedCornerShape(12.dp)).clickable(onClickLabel = h) { to = h }.padding(vertical = 6.dp),
                        tilt = if (on) -2f else 0f, size = 14,
                    )
                }
            }
            Label("note", color = InkFaint)
            BasicTextField(
                note, { note = it.take(200) },
                textStyle = TextStyle(color = Ink, fontSize = 15.sp, fontFamily = Rounded, fontWeight = FontWeight.Medium),
                cursorBrush = SolidColor(Ink), singleLine = true,
                decorationBox = { field ->
                    Box(
                        Modifier.fillMaxWidth().height(48.dp).background(Color(0xFFFFFBEE), RoundedCornerShape(16.dp))
                            .border(2.dp, Color(0xFFE3CC98), RoundedCornerShape(16.dp)).padding(horizontal = 16.dp),
                        contentAlignment = Alignment.CenterStart,
                    ) {
                        if (note.isEmpty()) Text("optional", color = InkFaint, fontSize = 15.sp)
                        field()
                    }
                },
            )
            Text(
                "Everyone here sees it wrapped; only ${to ?: "they"} can open it. You can take it back until they do.",
                color = InkDim, fontSize = 13.sp, lineHeight = 19.sp,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PaperButton("Cancel", close, Modifier.weight(1f).height(52.dp))
                PlasticButton(
                    {
                        val i = item
                        val t = to
                        if (i != null && t != null) {
                            app.post(("@$t " + note).trim(), i, count, t)
                            close()
                        }
                    },
                    Modifier.weight(2f).height(52.dp), tone = Tone.Orange, enabled = item != null && to != null && count in 1..max,
                ) { Text(if (item != null) "Wrap $count $item" else "Wrap", fontWeight = FontWeight.ExtraBold, fontSize = 15.sp) }
            }
        }
    }
}

/** Choices as plastic chips, wrapping onto rows. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun <T> ChipFlow(options: List<T>, selected: T?, label: (T) -> String, pick: (T) -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        options.forEach { o ->
            PlasticButton({ pick(o) }, tone = if (o == selected) Tone.Green else Tone.Plastic, shape = RoundedCornerShape(14.dp)) {
                Text(label(o), fontSize = 13.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

fun serverFor(app: AppState): Server? = (app.place as? Place.InServer)?.let { app.server(it.id) }

@Composable
fun Dot(color: Color) {
    Box(Modifier.size(8.dp).clip(androidx.compose.foundation.shape.CircleShape).background(color))
}
