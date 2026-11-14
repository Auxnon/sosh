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
) {
    companion object {
        /** What messages can be reacted with (`Sosh.Chat.reactions/0`). */
        val EMOJI = listOf("👍", "❤️", "😂", "😮", "😢", "🎉")

        fun from(o: JSONObject) = Message(
            o.optLong("id"), Person.from(o.optJSONObject("author")), o.optString("body"),
            o.optString("at"), Gift.from(o.optJSONObject("gift")), Media.from(o.optJSONObject("media")),
            o.optString("edited_at").takeIf { !o.isNull("edited_at") && it.isNotEmpty() },
            Reaction.list(o.optJSONArray("reactions")), o.optInt("pins"),
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

data class Conversation(val id: Long, val with: Person, val last: Message?) {
    companion object {
        fun from(o: JSONObject) = Conversation(
            o.optLong("id"), Person.from(o.optJSONObject("with"))!!,
            o.optJSONObject("last")?.let { Message.from(it) },
        )
    }
}

data class Slot(val item: String, val count: Int)

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
