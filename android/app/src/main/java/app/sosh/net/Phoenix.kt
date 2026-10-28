package app.sosh.net

import android.os.Handler
import android.os.Looper
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/** Where callbacks run: the main thread on Android (`MainScheduler`). */
interface Scheduler {
    fun post(r: Runnable)
    fun postDelayed(r: Runnable, ms: Long)
    fun cancelAll()
}

class MainScheduler : Scheduler {
    private val h = Handler(Looper.getMainLooper())
    override fun post(r: Runnable) { h.post(r) }
    override fun postDelayed(r: Runnable, ms: Long) { h.postDelayed(r, ms) }
    override fun cancelAll() = h.removeCallbacksAndMessages(null)
}

/**
 * A Phoenix Channels client (the v2 JSON protocol: frames are
 * `[join_ref, ref, topic, event, payload]`) over OkHttp's websocket.
 *
 * Everything it calls back runs on the main thread. It heartbeats every 25s,
 * reconnects with backoff when the connection drops and joins every channel
 * again, so callers set up channels once.
 */
class PhoenixSocket(
    /** ws(s)://host/socket/websocket, with any params (`token`). */
    private val url: String,
    private val main: Scheduler = MainScheduler(),
) {
    private val client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()
    private var ws: WebSocket? = null
    private var ref = 0
    private var open = false
    private var closed = false
    private var retries = 0
    private val channels = linkedMapOf<String, Channel>()
    private val replies = HashMap<String, (String, JSONObject) -> Unit>()

    /** Told true when connected, false when not. */
    var onState: (Boolean) -> Unit = {}

    private fun nextRef(): String = (++ref).toString()

    fun connect() {
        closed = false
        val request = Request.Builder().url(url).build()
        ws = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                main.post {
                    open = true
                    retries = 0
                    onState(true)
                    channels.values.forEach { it.rejoin() }
                    heartbeat()
                }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                main.post { dispatch(text) }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                main.post { dropped() }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                main.post { dropped() }
            }
        })
    }

    fun disconnect() {
        closed = true
        open = false
        main.cancelAll()
        ws?.close(1000, "bye")
        ws = null
        channels.values.forEach { it.joined = false }
    }

    private fun dropped() {
        if (!open && ws == null) return
        open = false
        ws = null
        channels.values.forEach { it.joined = false }
        onState(false)
        if (!closed) {
            val delay = listOf(1000L, 2000L, 5000L, 10000L)[retries.coerceAtMost(3)]
            retries++
            main.postDelayed({ if (!closed) connect() }, delay)
        }
    }

    private fun heartbeat() {
        main.postDelayed({
            if (open) {
                send(JSONArray().put(JSONObject.NULL).put(nextRef()).put("phoenix").put("heartbeat").put(JSONObject()))
                heartbeat()
            }
        }, 25_000)
    }

    private fun send(frame: JSONArray): Boolean = ws?.send(frame.toString()) ?: false

    fun channel(topic: String, params: JSONObject = JSONObject()): Channel {
        channels[topic]?.let { return it }
        val ch = Channel(topic, params)
        channels[topic] = ch
        if (open) ch.rejoin()
        return ch
    }

    private fun dispatch(text: String) {
        val msg = try { JSONArray(text) } catch (e: Exception) { return }
        val joinRef = msg.optString(0).takeIf { !msg.isNull(0) }
        val msgRef = msg.optString(1).takeIf { !msg.isNull(1) }
        val topic = msg.optString(2)
        val event = msg.optString(3)
        val payload = msg.optJSONObject(4) ?: JSONObject()
        if (event == "phx_reply") {
            val cb = msgRef?.let { replies.remove(it) }
            val status = payload.optString("status")
            val response = payload.optJSONObject("response") ?: JSONObject()
            cb?.invoke(status, response)
            return
        }
        val ch = channels[topic] ?: return
        if (event == "phx_error" || event == "phx_close") {
            if (joinRef == ch.joinRef) {
                ch.joined = false
                if (event == "phx_error" && open) main.postDelayed({ ch.rejoin() }, 1000)
            }
            return
        }
        ch.handlers[event]?.invoke(payload)
    }

    inner class Channel(val topic: String, private val params: JSONObject) {
        var joinRef: String? = null
        var joined = false
        internal val handlers = HashMap<String, (JSONObject) -> Unit>()
        var onJoin: (JSONObject) -> Unit = {}
        var onError: (JSONObject) -> Unit = {}
        private var left = false

        fun on(event: String, handler: (JSONObject) -> Unit): Channel {
            handlers[event] = handler
            return this
        }

        internal fun rejoin() {
            if (left || !open) return
            val r = nextRef()
            joinRef = r
            replies[r] = { status, response ->
                if (status == "ok") {
                    joined = true
                    onJoin(response)
                } else {
                    onError(response)
                }
            }
            send(JSONArray().put(r).put(r).put(topic).put("phx_join").put(params))
        }

        fun leave() {
            left = true
            if (joined) {
                send(JSONArray().put(joinRef).put(nextRef()).put(topic).put("phx_leave").put(JSONObject()))
            }
            joined = false
            channels.remove(topic)
        }

        /**
         * Push an event; `onReply(status, response)` with "ok" or "error"
         * (or "offline" straight away if the channel isn't joined).
         */
        fun push(event: String, payload: JSONObject = JSONObject(), onReply: ((String, JSONObject) -> Unit)? = null) {
            if (!joined) {
                onReply?.invoke("offline", JSONObject().put("reason", "offline"))
                return
            }
            val r = nextRef()
            if (onReply != null) replies[r] = onReply
            send(JSONArray().put(joinRef).put(r).put(topic).put(event).put(payload))
        }
    }
}
