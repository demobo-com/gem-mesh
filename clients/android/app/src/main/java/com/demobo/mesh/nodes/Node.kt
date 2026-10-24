package com.demobo.mesh.nodes

import org.json.JSONArray
import org.json.JSONObject

/** T0 is the phone itself; T1 laptop, T2 workstation, T3 server, T4 the frontier (Gemini). */
enum class Tier { T0, T1, T2, T3, T4;
    companion object { fun of(s: String?): Tier? = entries.firstOrNull { it.name == s } }
}

/**
 * A mesh node (docs/PROTOCOL.md §2): `url` is its root, e.g. http://192.168.1.20:9400, with /health, /mesh/info and
 * /v1/chat/completions under it. Tier, model and window come from /mesh/info once it answers.
 */
data class Node(
    val id: String,
    val device: String,
    val url: String,
    val tier: String = "?",
    val model: String = "",
    /** Found over mDNS rather than paired or added by hand; never saved. */
    val discovered: Boolean = false,
) {
    fun toJson(): JSONObject = JSONObject().put("id", id).put("device", device).put("url", url).put("tier", tier).put("model", model)

    /** host:port, to tell a paired node and the same node found over mDNS apart from different ones. */
    val address: String get() = url.removePrefix("http://").removePrefix("https://").trimEnd('/')

    companion object {
        fun fromJson(o: JSONObject) = Node(
            id = o.getString("id"), device = o.getString("device"), url = o.getString("url"),
            tier = o.optString("tier", "?"), model = o.optString("model", ""),
        )

        fun listToJson(nodes: List<Node>): String = JSONArray(nodes.map { it.toJson() }).toString()

        fun listFromJson(s: String): List<Node> {
            val a = JSONArray(s)
            return (0 until a.length()).map { fromJson(a.getJSONObject(it)) }
        }

        /** http://host:port from what a person typed: a bare host, host:port, or a URL with /v1 or a trailing slash. */
        fun normalizeUrl(s: String): String? {
            var u = s.trim().trimEnd('/')
            if (u.isEmpty()) return null
            if (!u.startsWith("http://") && !u.startsWith("https://")) u = "http://$u"
            u = u.removeSuffix("/v1")
            val hostPort = u.substringAfter("://")
            if (hostPort.isEmpty() || '/' in hostPort) return null
            return if (':' in hostPort) u else "$u:9400"
        }
    }
}

/** The frontier tier (Gemini, OpenAI-compatible endpoint). Never routed to; used only after the user approves. */
data class Frontier(
    val baseUrl: String = "https://generativelanguage.googleapis.com/v1beta/openai",
    val model: String = "gemini-2.5-flash",
    val apiKey: String = "",
)

/**
 * The pairing code `gem-mesh pair` prints (PROTOCOL §1):
 * {"v":1,"app":"gemma-mesh","mesh":"default","nodes":["http://192.168.1.20:9400"],"device":"my-macbook"}
 */
data class Pairing(val mesh: String, val nodes: List<String>, val device: String) {
    companion object {
        fun parse(s: String): Result<Pairing> = runCatching {
            val o = JSONObject(s.trim())
            require(o.optInt("v") == 1 && o.optString("app") in setOf("gem-mesh", "gemma-mesh")) { "not a Gem Mesh pairing code" }   // "gemma-mesh": codes from before the rename
            val nodes = o.optJSONArray("nodes")?.let { a -> (0 until a.length()).mapNotNull { Node.normalizeUrl(a.getString(it)) } }.orEmpty()
            require(nodes.isNotEmpty()) { "the code lists no address; run gem-mesh pair on the Mac while it is on Wi-Fi" }
            Pairing(o.optString("mesh", "default").ifBlank { "default" }, nodes, o.optString("device", "mac"))
        }
    }
}
