package com.demobo.mesh.policy

import org.json.JSONObject

data class Rule(val name: String, val regex: Regex)

data class ModelSpec(val id: String, val repo: String, val file: String, val bytes: Long) {
    val url: String get() = "https://huggingface.co/$repo/resolve/main/$file"
}

/**
 * The repo's `policy/` files, copied into the app's assets at build time (YAML converted to JSON).
 * Port of `core/meshcore/policy.py`: the same defaults when a key is missing.
 */
class Policy(
    val rules: List<Rule>,
    val terms: List<String>,
    private val ranks: Map<String, Int>,
    val windows: Map<String, Pair<String, String>>,
    val longPromptTokens: Int,
    val heavyTokens: Int,
    /** never | ask */
    val frontier: String,
    /** never | public */
    val web: String,
    val effort: Map<String, String>,
    val classifier: Boolean,
    val classifierPrompt: String,
    val models: Map<String, ModelSpec>,
) {
    fun rank(tier: String): Int = ranks[tier] ?: 99

    /** The higher of two tiers by rank (Python's `max(a, b, key=policy.rank)`, first wins a tie). */
    fun higher(a: String, b: String): String = if (rank(b) > rank(a)) b else a

    /** The same policy with the user's own terms (client names, codenames) added to the file's. */
    fun withTerms(extra: List<String>): Policy = if (extra.isEmpty()) this else Policy(
        rules, (terms + extra).distinctBy { it.lowercase() }, ranks, windows, longPromptTokens, heavyTokens,
        frontier, web, effort, classifier, classifierPrompt, models,
    )

    companion object {
        /** `read(name)` returns the text of `policy/<name>`, or null when the file is missing. */
        fun load(read: (String) -> String?): Policy {
            val tiers = read("tiers.json")?.let(::JSONObject) ?: JSONObject()
            val rulesDoc = read("rules.json")?.let(::JSONObject) ?: JSONObject()
            val modelsDoc = read("models.json")?.let(::JSONObject) ?: JSONObject()

            val rules = rulesDoc.optJSONArray("patterns")?.let { a ->
                (0 until a.length()).map { a.getJSONObject(it) }.mapNotNull { r ->
                    // A bad pattern is skipped, as in policy.py, rather than taking the app down.
                    runCatching { Rule(r.getString("name"), Regex(r.getString("regex"), RegexOption.IGNORE_CASE)) }.getOrNull()
                }
            } ?: emptyList()
            val terms = rulesDoc.optJSONArray("terms")?.let { a -> (0 until a.length()).map { a.get(it).toString() } } ?: emptyList()

            val ranks = tiers.optJSONObject("tiers")?.let { t -> t.keys().asSequence().associateWith { t.getJSONObject(it).optInt("rank", 99) } }
                ?: mapOf("T0" to 0, "T1" to 1, "T2" to 2, "T3" to 3, "T4" to 4)
            val windows = tiers.optJSONObject("windows")?.let { w ->
                w.keys().asSequence().associateWith { k -> w.getJSONObject(k).let { it.getString("floor") to it.getString("ceiling") } }
            } ?: mapOf("public" to ("T0" to "T3"), "sensitive" to ("T0" to "T3"))
            val diff = tiers.optJSONObject("difficulty")
            val effort = tiers.optJSONObject("effort")?.let { e -> e.keys().asSequence().associateWith { e.get(it).toString() } } ?: emptyMap()

            val models = modelsDoc.optJSONObject("models")?.let { m ->
                m.keys().asSequence().associateWith { id ->
                    m.getJSONObject(id).let { ModelSpec(id, it.getString("repo"), it.getString("file"), it.getLong("bytes")) }
                }
            } ?: emptyMap()

            return Policy(
                rules = rules,
                terms = terms,
                ranks = ranks,
                windows = windows,
                longPromptTokens = diff?.optInt("long_prompt_tokens", 1500) ?: 1500,
                heavyTokens = diff?.optInt("heavy_tokens", 12000) ?: 12000,
                frontier = tiers.opt("frontier")?.toString() ?: "ask",
                web = tiers.opt("web")?.toString() ?: "public",
                effort = effort,
                classifier = (tiers.opt("classifier")?.toString() ?: "on").lowercase() in setOf("on", "true", "yes", "1"),
                classifierPrompt = read("classifier.txt") ?: "",
                models = models,
            )
        }
    }
}
