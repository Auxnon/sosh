package app.sosh.data

import org.json.JSONArray
import org.json.JSONObject

/** Someone as anyone sees them. */
data class Person(val id: Long, val handle: String, val character: JSONObject?) {
    companion object {
        fun from(o: JSONObject?): Person? = o?.let {
            Person(it.optLong("id"), it.optString("handle"), it.optJSONObject("character"))
        }
    }
}

data class Me(val id: Long, val handle: String, val email: String, val character: JSONObject) {
    companion object {
        fun from(o: JSONObject) = Me(
            o.optLong("id"), o.optString("handle"), o.optString("email"),
            o.optJSONObject("character") ?: JSONObject(),
        )
    }
}

/** A server (a universe) and our place in it. */
data class Server(
    val id: Long,
    val name: String,
    val description: String,
    val universe: Pair<Int, Int>,
    val policy: String,
    val ownerId: Long?,
    /** "member", "pending", "invited", "banned", or null */
    val status: String?,
    val role: String?,
    val members: Int,
    /** Its universe's map, a picture of its islands (`/map/gx,gy`): the banner. */
    val map: String? = null,
) {
    val isMember get() = status == "member"

    /** What the role may do (the server's `Sosh.Servers.perms/1`). */
    fun can(perm: String): Boolean {
        val ranks = listOf("member", "moderator", "admin", "owner")
        val needs = mapOf(
            "approve" to "moderator", "kick" to "moderator", "manage_messages" to "moderator",
            "invite" to "admin", "ban" to "admin", "set_roles" to "admin", "manage_server" to "owner",
        )
        val r = ranks.indexOf(role ?: return false)
        return r >= ranks.indexOf(needs[perm] ?: "member")
    }

    companion object {
        fun from(o: JSONObject): Server {
            val u = o.optJSONArray("universe") ?: JSONArray()
            return Server(
                o.optLong("id"), o.optString("name"), o.optString("description"),
                u.optInt(0) to u.optInt(1), o.optString("policy"),
                if (o.isNull("owner_id")) null else o.optLong("owner_id"),
                o.optString("status").takeIf { !o.isNull("status") && it.isNotEmpty() },
                o.optString("role").takeIf { !o.isNull("role") && it != "false" && it.isNotEmpty() },
                o.optInt("members"),
                o.optString("map").takeIf { !o.isNull("map") && it.startsWith("/") },
            )
        }
    }
}

data class Member(val person: Person, val role: String, val status: String) {
    companion object {
        fun from(o: JSONObject) = Member(Person.from(o.optJSONObject("user"))!!, o.optString("role"), o.optString("status"))
    }
}

data class Friends(
    val friends: List<Person> = emptyList(),
    val incoming: List<Person> = emptyList(),
    val outgoing: List<Person> = emptyList(),
) {
    companion object {
        fun from(o: JSONObject) = Friends(people(o.optJSONArray("friends")), people(o.optJSONArray("incoming")), people(o.optJSONArray("outgoing")))
    }
}

fun people(a: JSONArray?): List<Person> =
    (0 until (a?.length() ?: 0)).mapNotNull { Person.from(a!!.optJSONObject(it)) }

/** Items for one person, carried by a message. */
data class Gift(val to: Person?, val state: String, val item: String?, val count: Int?) {
    companion object {
        fun from(o: JSONObject?): Gift? = o?.let {
            Gift(
                Person.from(it.optJSONObject("to")), it.optString("state"),
                it.optString("item").takeIf { s -> !it.isNull("item") && s.isNotEmpty() },
                if (it.has("count") && !it.isNull("count")) it.optInt("count") else null,
            )
        }
    }
}

/** One emoji on a message, and who put it there (user ids). */
data class Reaction(val emoji: String, val users: List<Long>) {
    companion object {
        fun list(a: JSONArray?): List<Reaction> = (0 until (a?.length() ?: 0)).mapNotNull { i ->
            a!!.optJSONObject(i)?.let { o ->
                val u = o.optJSONArray("users")
                Reaction(o.optString("emoji"), (0 until (u?.length() ?: 0)).map { u!!.optLong(it) })
            }
        }
    }
}

data class Message(
    val id: Long,
    val author: Person?,
    val body: String,
    val at: String,
    val gift: Gift?,
    val media: Media? = null,
    val editedAt: String? = null,
    val reactions: List<Reaction> = emptyList(),
    /** How many signs were made of it (pinned). */
    val pins: Int = 0,
    /** Previews of the links in it (`Sosh.Embeds`), filled in after it's sent. */
    val embeds: List<Embed> = emptyList(),
) {
    companion object {
        /** What messages can be reacted with (`Sosh.Chat.reactions/0`). */
        val EMOJI = listOf("👍", "❤️", "😂", "😮", "😢", "🎉")

        fun from(o: JSONObject) = Message(
            o.optLong("id"), Person.from(o.optJSONObject("author")), o.optString("body"),
            o.optString("at"), Gift.from(o.optJSONObject("gift")), Media.from(o.optJSONObject("media")),
            o.optString("edited_at").takeIf { !o.isNull("edited_at") && it.isNotEmpty() },
            Reaction.list(o.optJSONArray("reactions")), o.optInt("pins"),
            Embed.list(o.optJSONArray("embeds")),
        )
    }
}

/**
 * A picture or a Petrichor64 cart shared in a message (`Sosh.Media.view`):
 * `url` is relative to the server; `kind` "image" or "cart".
 */
data class Media(
    val key: String,
    val url: String,
    val kind: String,
    val mime: String,
    val animated: Boolean,
    val w: Int,
    val h: Int,
    val size: Long,
    val name: String?,
) {
    val isCart get() = kind == "cart"

    /** What it's called where it can't be shown. */
    val label: String
        get() = when {
            isCart -> (name ?: "a game").removeSuffix(".png").removeSuffix(".game")
            animated -> "a moving picture"
            else -> "a picture"
        }

    companion object {
        fun from(o: JSONObject?): Media? {
            if (o == null || !o.has("key")) return null
            return Media(
                o.optString("key"), o.optString("url"), o.optString("kind", "image"), o.optString("mime"),
                o.optBoolean("animated"), o.optInt("w", 1), o.optInt("h", 1), o.optLong("size"),
                o.optString("name").takeIf { o.has("name") && !o.isNull("name") && it.isNotEmpty() },
            )
        }
    }
}

/**
 * A link's preview (`Sosh.Embeds`): a post or video on another app. Only
 * `url` and `provider` are sure; `thumb` is a picture kept by the server.
 */
data class Embed(
    val url: String,
    val provider: String,
    val title: String?,
    val author: String?,
    val text: String?,
    val thumb: Media?,
    /** A video: its picture gets a play mark, and opening it goes to the app. */
    val video: Boolean = false,
) {
    /** The app it's from, as people call it. */
    val app: String
        get() = when (provider) {
            "x" -> "X"
            "instagram" -> "Instagram"
            "threads" -> "Threads"
            "bluesky" -> "Bluesky"
            "mastodon" -> "Mastodon"
            "youtube" -> "YouTube"
            "tiktok" -> "TikTok"
            "reddit" -> "Reddit"
            "spotify" -> "Spotify"
            "vimeo" -> "Vimeo"
            "soundcloud" -> "SoundCloud"
            else -> provider
        }

    companion object {
        private fun JSONObject.str(k: String) = optString(k).takeIf { has(k) && !isNull(k) && it.isNotEmpty() }

        fun list(a: JSONArray?): List<Embed> = (0 until (a?.length() ?: 0)).mapNotNull { i ->
            val o = a!!.optJSONObject(i) ?: return@mapNotNull null
            val url = o.str("url") ?: return@mapNotNull null
            Embed(url, o.optString("provider"), o.str("title"), o.str("author"), o.str("text"), Media.from(o.optJSONObject("thumb")), o.optBoolean("video"))
        }
    }
}

data class Conversation(val id: Long, val with: Person, val last: Message?) {
    companion object {
        fun from(o: JSONObject) = Conversation(
            o.optLong("id"), Person.from(o.optJSONObject("with"))!!,
            o.optJSONObject("last")?.let { Message.from(it) },
        )
    }
}

data class Slot(val item: String, val count: Int) {
    /** How many marbles, for a bag of them (`marbles:<n>`). */
    val marbles: Int? get() = Regex("^marbles:(\\d+)$").find(item)?.groupValues?.get(1)?.toIntOrNull()

    /** The number on its pocket: a bag of marbles says how many are in it. */
    val label: String get() = marbles?.let(::shortCount) ?: "$count"
}

/** A count short enough for a pocket: 12345 is 12k. */
fun shortCount(n: Int): String = when {
    n >= 1_000_000 -> "${n / 1_000_000}m"
    n >= 10_000 -> "${n / 1000}k"
    else -> "$n"
}

fun bag(a: JSONArray?): List<Slot?> = (0 until (a?.length() ?: 0)).map { i ->
    val s = a!!.optJSONArray(i)
    if (s == null || s.length() < 2) null else Slot(s.optString(0), s.optInt(1))
}

/** What the character creator offers (`Sosh.Character.catalog/0`). */
data class Catalog(
    val heads: List<String>,
    val hair: List<String>,
    val clothes: Map<String, List<String>>,
    val parts: Map<String, Int>,
    val maxFace: Int,
) {
    companion object {
        fun from(o: JSONObject?): Catalog {
            if (o == null) return default
            val cl = o.optJSONObject("clothes") ?: JSONObject()
            val parts = o.optJSONObject("parts") ?: JSONObject()
            return Catalog(
                strings(o.optJSONArray("heads")), strings(o.optJSONArray("hair")),
                cl.keys().asSequence().associateWith { strings(cl.optJSONArray(it)) },
                parts.keys().asSequence().associateWith { parts.optInt(it) },
                o.optInt("max_face", 12),
            )
        }

        val default = Catalog(
            listOf("round", "square", "long", "bean"),
            listOf("none", "short", "tuft", "bob", "spikes", "long"),
            mapOf(
                "top" to listOf("none", "tee", "jacket", "sweater"),
                "bottom" to listOf("none", "pants", "shorts", "skirt"),
                "shoes" to listOf("none", "shoes", "boots"),
                "hat" to listOf("none", "cap", "beanie", "tophat"),
            ),
            mapOf("eye" to 6, "brow" to 4, "mouth" to 6, "nose" to 4, "cheek" to 2, "mark" to 4),
            12,
        )
    }
}

fun strings(a: JSONArray?): List<String> = (0 until (a?.length() ?: 0)).map { a!!.optString(it) }
