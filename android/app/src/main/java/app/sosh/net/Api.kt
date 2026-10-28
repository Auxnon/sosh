package app.sosh.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/** A refused request: `reason` is the server's (`bad_login`, `forbidden`...). */
class ApiError(val status: Int, val reason: String, message: String) : Exception(message)

/**
 * The account API (`/api`, see the server's router): JSON in, JSON out,
 * signed in with `Authorization: Bearer <token>`.
 */
class Api(private val base: String, var token: String? = null) {
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()
    private val json = "application/json".toMediaType()

    suspend fun get(path: String): JSONObject = call("GET", path, null)
    suspend fun post(path: String, body: JSONObject = JSONObject()): JSONObject = call("POST", path, body)
    suspend fun put(path: String, body: JSONObject): JSONObject = call("PUT", path, body)
    suspend fun patch(path: String, body: JSONObject): JSONObject = call("PATCH", path, body)
    suspend fun delete(path: String): JSONObject = call("DELETE", path, null)

    private suspend fun call(method: String, path: String, body: JSONObject?): JSONObject =
        withContext(Dispatchers.IO) {
            val b = Request.Builder().url(base.trimEnd('/') + "/api" + path)
            token?.let { b.header("Authorization", "Bearer $it") }
            val rb = body?.toString()?.toRequestBody(json)
            when (method) {
                "GET" -> b.get()
                "DELETE" -> b.delete()
                else -> b.method(method, rb ?: "{}".toRequestBody(json))
            }
            client.newCall(b.build()).execute().use { r ->
                val text = r.body?.string().orEmpty()
                val obj = try { JSONObject(text) } catch (e: Exception) { JSONObject() }
                if (!r.isSuccessful) {
                    val reason = obj.optString("error", "http_${r.code}")
                    throw ApiError(r.code, reason, describe(reason, obj))
                }
                obj
            }
        }

    companion object {
        private val messages = mapOf(
            "bad_login" to "Wrong email or password.",
            "unconfirmed" to "Confirm your email first: we sent a new code.",
            "bad_code" to "That code didn't work.",
            "rate_limited" to "Too many tries. Wait a few minutes.",
            "forbidden" to "You can't do that here.",
            "signed_out" to "Signed out.",
            "no_such_user" to "No one has that handle.",
            "not_enough" to "You don't have that many.",
            "no_room" to "No room in your bag for that.",
            "not_yours" to "That isn't yours to open.",
            "already" to "That gift is already settled.",
            "banned" to "You're banned from that server.",
            "yourself" to "That's you.",
            "not_a_member" to "They aren't a member here.",
        )

        /** A sentence for a reason (and the first field error, if invalid). */
        fun describe(reason: String, body: JSONObject? = null): String {
            if (reason == "invalid" && body != null) {
                val errors = body.optJSONObject("errors")
                if (errors != null) {
                    val key = errors.keys().asSequence().firstOrNull()
                    if (key != null) return "$key ${errors.optJSONArray(key)?.optString(0) ?: "is invalid"}"
                }
            }
            return messages[reason] ?: reason.replace('_', ' ')
        }
    }
}
