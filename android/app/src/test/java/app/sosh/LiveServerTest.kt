package app.sosh

import app.sosh.data.Catalog
import app.sosh.data.Conversation
import app.sosh.data.Friends
import app.sosh.data.Me
import app.sosh.data.Message
import app.sosh.data.Server
import app.sosh.data.bag
import app.sosh.net.Api
import app.sosh.net.ApiError
import app.sosh.net.PhoenixSocket
import app.sosh.net.Scheduler
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * The app's network code and models against a running dev server (`just
 * serve`; SOSH_SERVER to point elsewhere). Skipped when there isn't one.
 * Codes are read from the dev mailbox (/dev/mailbox/json).
 */
class LiveServerTest {
    private val base = System.getenv("SOSH_SERVER") ?: "http://localhost:4000"
    private val http = OkHttpClient()
    private val run = System.nanoTime().toString().takeLast(7)

    @Before
    fun serverIsUp() {
        val up = try {
            http.newCall(Request.Builder().url("$base/api/hello").build()).execute().use { it.isSuccessful }
        } catch (e: Exception) {
            false
        }
        assumeTrue("no dev server at $base", up)
    }

    private fun codeFor(email: String): String {
        val body = http.newCall(Request.Builder().url("$base/dev/mailbox/json").build()).execute().use { it.body!!.string() }
        val mail = JSONObject(body).getJSONArray("data")
        for (i in 0 until mail.length()) {
            val m = mail.getJSONObject(i)
            if (m.getJSONArray("to").getString(0) == email) {
                return Regex("\\d{6}").find(m.getString("subject"))!!.value
            }
        }
        error("no mail for $email")
    }

    /** A new, confirmed account: (api signed in, me). */
    private fun account(name: String): Pair<Api, Me> = runBlocking {
        val email = "$name$run@example.com"
        val api = Api(base)
        val r = api.post("/auth/register", JSONObject().put("email", email).put("handle", "$name$run").put("password", "a long passphrase"))
        assertEquals("confirm", r.getString("status"))
        val s = api.post("/auth/confirm", JSONObject().put("email", email).put("code", codeFor(email)))
        api.token = s.getString("token")
        api to Me.from(s.getJSONObject("user"))
    }

    /** Runs callbacks on one thread, as the main thread would. */
    private class TestScheduler : Scheduler {
        val ex = Executors.newSingleThreadScheduledExecutor()
        override fun post(r: Runnable) { ex.execute(r) }
        override fun postDelayed(r: Runnable, ms: Long) { ex.schedule(r, ms, TimeUnit.MILLISECONDS) }
        override fun cancelAll() {}
    }

    private fun socket(token: String): PhoenixSocket {
        val ws = base.replaceFirst("http", "ws") + "/socket/websocket?vsn=2.0.0&token=$token"
        return PhoenixSocket(ws, TestScheduler())
    }

    @Test
    fun accountsServersFriendsAndDms() = runBlocking {
        val (ann, annMe) = account("ann")
        val (_, benMe) = account("ben")

        val all = ann.get("/me")
        assertEquals(annMe.handle, Me.from(all.getJSONObject("user")).handle)
        assertTrue(Catalog.from(all.getJSONObject("catalog")).heads.contains("bean"))
        assertTrue(bag(all.getJSONArray("bag")).filterNotNull().any { it.item == "wood" })

        val servers = (0 until all.getJSONArray("servers").length()).map { Server.from(all.getJSONArray("servers").getJSONObject(it)) }
        assertEquals(10, servers.size)
        val plaza = servers.first { it.universe == (0 to 0) }
        assertTrue(plaza.isMember)
        assertTrue(!plaza.can("kick"))

        // friends
        ann.post("/friends", JSONObject().put("handle", benMe.handle))
        val ben = Api(base, null).also { it.token = null }
        val f = Friends.from(ann.get("/friends"))
        assertEquals(listOf(benMe.handle), f.outgoing.map { it.handle })

        // a direct message with a gift in it, parsed as the app does
        val m = Message.from(
            ann.post(
                "/dms/${benMe.handle}/messages",
                JSONObject().put("body", "hi").put("gift", JSONObject().put("item", "stone").put("count", 2).put("to", benMe.handle)),
            ).getJSONObject("message")
        )
        assertEquals("sealed", m.gift!!.state)
        assertEquals("stone", m.gift!!.item)
        val c = Conversation.from(ann.get("/dms").getJSONArray("conversations").getJSONObject(0))
        assertEquals(benMe.handle, c.with.handle)

        // wrong password, as the app shows it
        try {
            ben.post("/auth/login", JSONObject().put("email", "ben$run@example.com").put("password", "nope nope nope"))
            error("signed in with a wrong password")
        } catch (e: ApiError) {
            assertEquals("bad_login", e.reason)
            assertEquals("Wrong email or password.", e.message)
        }
    }

    @Test
    fun aGiftInTheServerChatOverTheSocket() = runBlocking {
        val (ann, _) = account("gia")
        val (ben, benMe) = account("gib")
        val plaza = Server.from(
            ann.get("/servers").getJSONArray("servers").let { a ->
                (0 until a.length()).map { a.getJSONObject(it) }.first { it.getJSONArray("universe").getInt(0) == 0 && it.getJSONArray("universe").getInt(1) == 0 }
            }
        )

        val events = LinkedBlockingQueue<Pair<String, JSONObject>>()
        val sa = socket(ann.token!!)
        val sb = socket(ben.token!!)
        val joined = LinkedBlockingQueue<String>()
        val chA = sa.channel("server:${plaza.id}").also { it.onJoin = { joined.put("a") } }
        val chB = sb.channel("server:${plaza.id}").also {
            it.onJoin = { joined.put("b") }
            it.on("message") { m -> events.put("message" to m) }
            it.on("gift") { m -> events.put("gift" to m) }
        }
        sa.connect()
        sb.connect()
        assertNotNull(joined.poll(10, TimeUnit.SECONDS))
        assertNotNull(joined.poll(10, TimeUnit.SECONDS))

        val reply = LinkedBlockingQueue<Pair<String, JSONObject>>()
        chA.push(
            "post",
            JSONObject().put("body", "@${benMe.handle} catch").put("gift", JSONObject().put("item", "wood").put("count", 3).put("to", benMe.handle)),
        ) { status, r -> reply.put(status to r) }
        val (status, r) = reply.poll(10, TimeUnit.SECONDS)!!
        assertEquals("ok", status)
        val sent = Message.from(r.getJSONObject("message"))
        assertEquals("wood", sent.gift!!.item)

        // ben sees it wrapped: who it's for, not what's in it
        val (event, payload) = events.poll(10, TimeUnit.SECONDS)!!
        assertEquals("message", event)
        val seen = Message.from(payload)
        assertEquals(sent.id, seen.id)
        assertEquals(benMe.handle, seen.gift!!.to!!.handle)
        assertNull(seen.gift!!.item)

        // only ben opens it
        try {
            ann.post("/messages/${sent.id}/claim")
            error("the sender opened it")
        } catch (e: ApiError) {
            assertEquals("not_yours", e.reason)
        }
        val opened = Message.from(ben.post("/messages/${sent.id}/claim").getJSONObject("message"))
        assertEquals("opened", opened.gift!!.state)
        assertEquals(3, opened.gift!!.count)
        val (ev2, p2) = events.poll(10, TimeUnit.SECONDS)!!
        assertEquals("gift", ev2)
        assertEquals("opened", Message.from(p2).gift!!.state)

        sa.disconnect()
        sb.disconnect()
        chB.leave()
    }
}
