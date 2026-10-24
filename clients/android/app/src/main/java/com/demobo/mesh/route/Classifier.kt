package com.demobo.mesh.route

import android.util.Log
import org.json.JSONObject
import java.security.MessageDigest

/**
 * The privacy label for a conversation the rules passed, from `policy/classifier.txt`. Port of
 * `ClientSession.classify`: runs on the lowest-tier model reachable (the phone's own when it is loaded), never
 * outside the mesh; unknown, unparseable or failed counts as sensitive (the router does that).
 */
class Classifier(private val prompt: String) {
    private val cache = HashMap<String, Pair<String, String>>()

    /**
     * `ask(system, user)` runs one ephemeral request on `device` and returns its text. `text` is already without
     * attachments ([textOf]); the last 3,000 characters are read.
     */
    suspend fun classify(text: String, device: String?, ask: (suspend (String, String) -> String)?): Pair<String, String> {
        val t = text.takeLast(3000)
        val key = sha1(t)
        cache[key]?.let { return it }
        if (device == null || ask == null) return "unknown" to "no model reachable to classify"
        val res = try {
            val out = ask(prompt, "CONVERSATION:\n$t")
            val o = Regex("""\{.*?\}""", RegexOption.DOT_MATCHES_ALL).find(out)?.value?.let { runCatching { JSONObject(it) }.getOrNull() }
            val label = o?.optString("label", "unknown")?.lowercase()?.trim() ?: "unknown"
            (if (label in setOf("public", "sensitive", "unknown")) label else "unknown") to
                ((o?.optString("reason", "") ?: "").take(80) + " · $device")
        } catch (e: Throwable) {
            Log.w(TAG, "classifier failed", e)
            "unknown" to "classifier failed: ${e.javaClass.simpleName}"
        }
        cache[key] = res
        return res
    }

    private fun sha1(s: String): String =
        MessageDigest.getInstance("SHA-1").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }

    companion object {
        private const val TAG = "Classifier"

        /**
         * The conversation as the classifier reads it: every message without the files attached to it, so a document
         * never decides the label but every turn the user typed does (session.classify cut the whole conversation at
         * the first attachment, which hid every later turn).
         */
        fun textOf(messages: List<String>): String = messages.joinToString("\n") { it.split("\n\n--- file:")[0] }
    }
}
