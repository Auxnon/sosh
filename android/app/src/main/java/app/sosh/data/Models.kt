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

data class Message(
    val id: Long,
    val author: Person?,
    val body: String,
    val at: String,
    val gift: Gift?,
) {
    companion object {
        fun from(o: JSONObject) = Message(
            o.optLong("id"), Person.from(o.optJSONObject("author")), o.optString("body"),
            o.optString("at"), Gift.from(o.optJSONObject("gift")),
        )
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
