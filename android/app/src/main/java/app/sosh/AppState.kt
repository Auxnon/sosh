package app.sosh

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.sosh.data.Catalog
import app.sosh.data.Conversation
import app.sosh.data.Friends
import app.sosh.data.Me
import app.sosh.data.Member
import app.sosh.data.Message
import app.sosh.data.Server
import app.sosh.data.SessionStore
import app.sosh.data.Slot
import app.sosh.data.bag
import app.sosh.net.Api
import app.sosh.net.ApiError
import app.sosh.net.PhoenixSocket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/** Where the chat pane is: a server's chat, or a conversation with someone. */
sealed class Place {
    data class InServer(val id: Long) : Place()
    data class WithPerson(val handle: String) : Place()
}

/**
 * How much of a server's world shows over its chat: none, the two side by
 * side (stacked, held upright), or all world with the chat over it.
 */
enum class Pane { Chat, Both, World }

/**
 * Everything the app knows and does. The REST API (`Api`) signs in and
 * manages things; the socket (`PhoenixSocket`) brings everything live:
 * `user:<id>` for our own changes, and one chat channel at a time
 * (`server:<id>` or `dm:<id>`) for the pane that's open.
 */
class AppState(context: Context, private val scope: CoroutineScope) {
    private val store = SessionStore(context)

    var serverUrl by mutableStateOf(store.server ?: BuildConfig.DEFAULT_SERVER)
        private set
    var token: String? by mutableStateOf(null)
        private set
    var me: Me? by mutableStateOf(null)
        private set
    /** Signing in from a saved token, before we know it's still good. */
    var restoring by mutableStateOf(false)
        private set
    var online by mutableStateOf(false)
        private set

    val servers = mutableStateListOf<Server>()
    var friends by mutableStateOf(Friends())
        private set
    val conversations = mutableStateListOf<Conversation>()
    var bag by mutableStateOf<List<Slot?>>(emptyList())
        private set
    var catalog by mutableStateOf(Catalog.default)
        private set

    var place: Place? by mutableStateOf(null)
        private set
    val messages = mutableStateListOf<Message>()
    /** In a server: how much of its world is showing. */
    var pane by mutableStateOf(Pane.Chat)
    val members = mutableStateListOf<Member>()
    var loadingOlder by mutableStateOf(false)
        private set

    /** A line to show briefly (errors, confirmations). */
    var notice: String? by mutableStateOf(null)

    private var api = Api(serverUrl)
    private var socket: PhoenixSocket? = null
    private var user: PhoenixSocket.Channel? = null
    private var chat: PhoenixSocket.Channel? = null

    init {
        store.token?.let { saved ->
            restoring = true
            api.token = saved
            scope.launch {
                try {
                    val all = api.get("/me")
                    startSession(saved, Me.from(all.getJSONObject("user")))
                    absorb(all)
                } catch (e: ApiError) {
                    if (e.status == 401) store.token = null
                } catch (e: Exception) {
                    notice = "Can't reach the server."
                } finally {
                    restoring = false
                }
            }
        }
    }

    fun setServer(url: String) {
        val u = url.trim().trimEnd('/')
        serverUrl = u
        store.server = u
        api = Api(u, token)
    }

    /** The websocket address for the API's server. */
    fun socketUrl(): String {
        val ws = serverUrl.replaceFirst("https://", "wss://").replaceFirst("http://", "ws://")
        return "$ws/socket/websocket?vsn=2.0.0"
    }

    // -- signing in

    /** Run a call, putting any error in `notice`; true if it worked. */
    private suspend fun attempt(block: suspend () -> Unit): Boolean = try {
        block()
        true
    } catch (e: ApiError) {
        notice = e.message
        false
    } catch (e: Exception) {
        notice = "Can't reach the server."
        false
    }

    fun login(email: String, password: String, done: (String?) -> Unit) = scope.launch {
        try {
            signedIn(api.post("/auth/login", JSONObject().put("email", email).put("password", password)))
            done(null)
        } catch (e: ApiError) {
            done(e.reason)
            notice = e.message
        } catch (e: Exception) {
            notice = "Can't reach the server."
        }
    }

    /** Sign up: `done(true)` when a code was emailed. */
    fun register(email: String, handle: String, password: String, done: (Boolean) -> Unit) = scope.launch {
        attempt {
            val r = api.post("/auth/register", JSONObject().put("email", email).put("handle", handle).put("password", password))
            if (r.has("token")) signedIn(r) else done(true)
        }
    }

    fun confirm(email: String, code: String) = scope.launch {
        attempt { signedIn(api.post("/auth/confirm", JSONObject().put("email", email).put("code", code))) }
    }

    fun resend(email: String) = scope.launch {
        attempt { api.post("/auth/resend", JSONObject().put("email", email)) }
        notice = "If that address needs it, a new code is on its way."
    }

    fun forgot(email: String, done: () -> Unit) = scope.launch {
        if (attempt { api.post("/auth/forgot", JSONObject().put("email", email)) }) done()
    }

    fun reset(email: String, code: String, password: String) = scope.launch {
        attempt {
            signedIn(api.post("/auth/reset", JSONObject().put("email", email).put("code", code).put("password", password)))
        }
    }

    private suspend fun signedIn(r: JSONObject) {
        val t = r.getString("token")
        store.token = t
        api.token = t
        startSession(t, Me.from(r.getJSONObject("user")))
        absorb(api.get("/me"))
    }

    private fun startSession(t: String, m: Me) {
        token = t
        me = m
        connect()
    }

    fun logout() {
        val t = token
        scope.launch { if (t != null) runCatching { api.delete("/auth/session") } }
        socket?.disconnect()
        socket = null
        user = null
        chat = null
        store.token = null
        token = null
        me = null
        place = null
        servers.clear()
        conversations.clear()
        messages.clear()
        members.clear()
        friends = Friends()
    }

    // -- live

    private fun connect() {
        socket?.disconnect()
        val s = PhoenixSocket(socketUrl() + "&token=" + token)
        s.onState = { online = it }
        socket = s
        val u = s.channel("user:${me!!.id}")
        u.onJoin = { absorb(it) }
        u.onError = { if (it.optString("reason") == "signed_out") logout() }
        u.on("servers") { refreshServers() }
        u.on("friends") { refreshFriends() }
        u.on("bag") { bag = bag(it.optJSONArray("bag")) }
        u.on("character") { c -> me = me?.copy(character = c.optJSONObject("character") ?: JSONObject()) }
        u.on("dm") { refreshConversations() }
        u.on("gift") { p ->
            val from = p.optJSONObject("from")?.optString("handle") ?: "someone"
            notice = "@$from sent you a gift"
        }
        u.on("removed") { p ->
            val id = p.optLong("server_id")
            if (place == Place.InServer(id)) open(null)
            refreshServers()
        }
        user = u
        s.connect()
        place?.let { open(it) }
    }

    /** Take in an "everything" answer (`Sosh.Me.everything/1`). */
    private fun absorb(all: JSONObject) {
        all.optJSONObject("user")?.let { me = Me.from(it) }
        all.optJSONArray("servers")?.let { setServers(it) }
        all.optJSONObject("friends")?.let { friends = Friends.from(it) }
        all.optJSONArray("conversations")?.let { setConversations(it) }
        all.optJSONArray("bag")?.let { bag = bag(it) }
        all.optJSONObject("catalog")?.let { catalog = Catalog.from(it) }
        if (place == null) servers.firstOrNull { it.isMember }?.let { open(Place.InServer(it.id)) }
    }

    private fun setServers(a: JSONArray) {
        servers.clear()
        for (i in 0 until a.length()) servers.add(Server.from(a.getJSONObject(i)))
    }

    private fun setConversations(a: JSONArray) {
        conversations.clear()
        for (i in 0 until a.length()) conversations.add(Conversation.from(a.getJSONObject(i)))
    }

    fun refreshServers() = scope.launch { attempt { setServers(api.get("/servers").getJSONArray("servers")) } }
    fun refreshFriends() = scope.launch { attempt { friends = Friends.from(api.get("/friends")) } }
    fun refreshConversations() = scope.launch { attempt { setConversations(api.get("/dms").getJSONArray("conversations")) } }

    fun server(id: Long): Server? = servers.firstOrNull { it.id == id }

    // -- the chat pane

    /** Show a server's chat or a conversation (null: nothing). */
    fun open(p: Place?) {
        chat?.leave()
        chat = null
        place = p
        messages.clear()
        members.clear()
        val s = socket ?: return
        when (p) {
            null -> {}
            is Place.InServer -> {
                val ch = s.channel("server:${p.id}")
                ch.onJoin = { r -> setMessages(r.optJSONArray("messages")) }
                ch.onError = { r -> notice = Api.describe(r.optString("reason")) }
                bindChat(ch)
                ch.on("members") { loadMembers() }
                ch.on("removed") { open(null); refreshServers() }
                chat = ch
                loadMembers()
            }
            is Place.WithPerson -> scope.launch {
                attempt {
                    val r = api.get("/dms/${p.handle}/messages")
                    val ch = s.channel("dm:${r.getLong("conversation_id")}")
                    ch.onJoin = { j -> setMessages(j.optJSONArray("messages")) }
                    bindChat(ch)
                    chat = ch
                    setMessages(r.optJSONArray("messages"))
                }
            }
        }
    }

    private fun bindChat(ch: PhoenixSocket.Channel) {
        ch.on("message") { m -> upsert(Message.from(m)) }
        ch.on("gift") { m -> upsert(Message.from(m), keepMine = true) }
        ch.on("deleted") { d -> messages.removeAll { it.id == d.optLong("id") } }
    }

    private fun setMessages(a: JSONArray?) {
        messages.clear()
        for (i in 0 until (a?.length() ?: 0)) messages.add(Message.from(a!!.getJSONObject(i)))
    }

    /**
     * A message in (or changed). Broadcasts carry gifts sealed for
     * everyone; what we know of our own (what we sent, what we opened)
     * stays.
     */
    private fun upsert(m: Message, keepMine: Boolean = false) {
        val i = messages.indexOfFirst { it.id == m.id }
        if (i < 0) {
            messages.add(m)
            return
        }
        val old = messages[i]
        val gift = if (keepMine && old.gift?.item != null && m.gift != null)
            m.gift.copy(item = old.gift.item, count = old.gift.count) else m.gift
        messages[i] = m.copy(gift = gift ?: old.gift)
    }

    fun loadOlder() {
        val first = messages.firstOrNull() ?: return
        val ch = chat ?: return
        if (loadingOlder) return
        loadingOlder = true
        ch.push("history", JSONObject().put("before", first.id)) { status, r ->
            loadingOlder = false
            if (status == "ok") {
                val a = r.optJSONArray("messages") ?: return@push
                val older = (0 until a.length()).map { Message.from(a.getJSONObject(it)) }
                messages.addAll(0, older)
            }
        }
    }

    /** Post to the open pane, with items for `giftTo` if given. */
    fun post(body: String, giftItem: String? = null, giftCount: Int = 1, giftTo: String? = null) {
        val payload = JSONObject().put("body", body)
        if (giftItem != null && giftTo != null) {
            payload.put("gift", JSONObject().put("item", giftItem).put("count", giftCount).put("to", giftTo))
        }
        val ch = chat
        if (ch == null) {
            notice = "Not connected."
            return
        }
        ch.push("post", payload) { status, r ->
            if (status == "ok") upsert(Message.from(r.getJSONObject("message")))
            else notice = Api.describe(r.optString("reason"))
        }
    }

    /** Send items to someone directly (a DM carrying them). */
    fun giftDirect(handle: String, item: String, count: Int, note: String) = scope.launch {
        attempt {
            api.post(
                "/dms/$handle/messages",
                JSONObject().put("body", note).put("gift", JSONObject().put("item", item).put("count", count).put("to", handle)),
            )
            notice = "Sent $count $item to @$handle."
            refreshConversations()
        }
    }

    fun claim(m: Message) = settle(m, "claim")
    fun cancel(m: Message) = settle(m, "cancel")

    private fun settle(m: Message, how: String) = scope.launch {
        attempt {
            val r = api.post("/messages/${m.id}/$how").getJSONObject("message")
            upsert(Message.from(r))
            val g = Message.from(r).gift
            if (how == "claim" && g?.item != null) notice = "${g.count} ${g.item}: in your bag."
        }
    }

    fun deleteMessage(m: Message) = scope.launch { attempt { api.delete("/messages/${m.id}") } }

    // -- servers and members

    fun loadMembers() {
        val p = place as? Place.InServer ?: return
        scope.launch {
            attempt {
                val a = api.get("/servers/${p.id}/members").getJSONArray("members")
                members.clear()
                for (i in 0 until a.length()) members.add(Member.from(a.getJSONObject(i)))
            }
        }
    }

    fun join(s: Server) = scope.launch {
        attempt {
            val status = api.post("/servers/${s.id}/join").optString("status")
            notice = if (status == "member") "Joined ${s.name}." else "Asked to join ${s.name}: someone there has to let you in."
            setServers(api.get("/servers").getJSONArray("servers"))
            if (status == "member") open(Place.InServer(s.id))
        }
    }

    fun leave(s: Server) = scope.launch {
        attempt {
            api.post("/servers/${s.id}/leave")
            if (place == Place.InServer(s.id)) open(null)
            setServers(api.get("/servers").getJSONArray("servers"))
        }
    }

    fun memberAction(s: Server, handle: String, action: String, role: String? = null) = scope.launch {
        attempt {
            val body = JSONObject()
            role?.let { body.put("role", it) }
            api.post("/servers/${s.id}/members/$handle/$action", body)
            loadMembers()
        }
    }

    fun invite(s: Server, handle: String) = scope.launch {
        if (attempt { api.post("/servers/${s.id}/invite", JSONObject().put("handle", handle)) }) notice = "Invited @$handle."
    }

    fun updateServer(s: Server, name: String, description: String, policy: String) = scope.launch {
        attempt {
            api.patch("/servers/${s.id}", JSONObject().put("name", name).put("description", description).put("policy", policy))
            setServers(api.get("/servers").getJSONArray("servers"))
        }
    }

    // -- friends

    fun addFriend(handle: String) = scope.launch {
        attempt {
            val st = api.post("/friends", JSONObject().put("handle", handle.trim().removePrefix("@"))).optString("status")
            notice = if (st == "accepted") "You're friends now." else "Asked @$handle."
            friends = Friends.from(api.get("/friends"))
        }
    }

    fun acceptFriend(handle: String) = scope.launch {
        attempt { api.post("/friends/$handle/accept"); friends = Friends.from(api.get("/friends")) }
    }

    fun removeFriend(handle: String) = scope.launch {
        attempt { api.delete("/friends/$handle"); friends = Friends.from(api.get("/friends")) }
    }

    // -- you

    fun saveCharacter(c: JSONObject, done: () -> Unit) = scope.launch {
        attempt {
            val r = api.put("/me/character", JSONObject().put("character", c))
            me = Me.from(r.getJSONObject("user"))
            done()
        }
    }
}
