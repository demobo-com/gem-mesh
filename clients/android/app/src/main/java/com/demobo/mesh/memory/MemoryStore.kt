package com.demobo.mesh.memory

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** One memory event (PROTOCOL §4). `id` is "<device>:<seq>", global, so copies merge with insert-or-ignore. */
data class Event(
    val id: String,
    val device: String,
    val seq: Long,
    /** Seconds since the epoch, as in the Python store. */
    val ts: Double,
    /** chat | fact | doc */
    val kind: String,
    val session: String?,
    val role: String?,
    val text: String,
    val meta: JSONObject,
) {
    fun toJson(): JSONObject = JSONObject().put("id", id).put("device", device).put("seq", seq).put("ts", ts).put("kind", kind)
        .put("session", session ?: JSONObject.NULL).put("role", role ?: JSONObject.NULL).put("text", text).put("meta", meta)

    companion object {
        fun fromJson(o: JSONObject) = Event(
            id = o.getString("id"), device = o.getString("device"), seq = o.getLong("seq"), ts = o.getDouble("ts"),
            kind = o.getString("kind"), session = o.optString("session").takeIf { !o.isNull("session") && it.isNotEmpty() },
            role = o.optString("role").takeIf { !o.isNull("role") && it.isNotEmpty() }, text = o.getString("text"),
            meta = o.optJSONObject("meta") ?: JSONObject(),
        )
    }
}

/** A conversation: the chat events of one session, from this phone or from the laptop's mirror. */
data class SessionSummary(val session: String, val title: String, val updated: Double, val turns: Int, val devices: Set<String>)

data class Hit(val event: Event, val score: Double)

/**
 * The user's memory on the phone: chat turns, facts and document chunks. Port of `core/meshcore/memory.py` with the
 * same `events` schema; the phone is the authority (PROTOCOL §4), so nothing here is ever pending. The laptop's
 * mirror pushes its own events here and pulls ours through [MemoryServer]. Vectors are not synced (each device
 * embeds for itself); until the phone has an embedding model, recall is by keywords.
 */
class MemoryStore(context: Context, val device: String) : SQLiteOpenHelper(context, "memory.db", null, 2) {

    /** Set once EmbeddingGemma is on the phone; until then recall is by keywords. */
    @Volatile var embedder: Embedder? = null

    init {
        context.deleteDatabase("mesh.db") // the pre-protocol chat store (test data only)
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS events (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT UNIQUE NOT NULL,
                device TEXT NOT NULL,
                seq INTEGER NOT NULL,
                ts REAL NOT NULL,
                kind TEXT NOT NULL,
                session TEXT,
                role TEXT,
                text TEXT NOT NULL,
                meta TEXT,
                pending INTEGER NOT NULL DEFAULT 0)""",
        )
        db.execSQL("CREATE TABLE IF NOT EXISTS vectors (id TEXT PRIMARY KEY, vec BLOB NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT)")
        db.execSQL("CREATE INDEX IF NOT EXISTS events_by_session ON events(session, rowid)")
        // Work waiting for a bigger tier (session.py's queue database); local to the phone, never synced.
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS tasks (
                id INTEGER PRIMARY KEY AUTOINCREMENT, created REAL, session TEXT, prompt TEXT, needs TEXT,
                status TEXT DEFAULT 'waiting', node TEXT, result TEXT, done REAL)""",
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = onCreate(db) // v2 added vectors

    private val cols = "id, device, seq, ts, kind, session, role, text, meta"

    private fun Cursor.event(offset: Int = 0) = Event(
        getString(offset), getString(offset + 1), getLong(offset + 2), getDouble(offset + 3), getString(offset + 4),
        if (isNull(offset + 5)) null else getString(offset + 5), if (isNull(offset + 6)) null else getString(offset + 6),
        getString(offset + 7), runCatching { JSONObject(getString(offset + 8) ?: "{}") }.getOrDefault(JSONObject()),
    )

    // ---- writing ------------------------------------------------------------------------------

    /** Appends an event written on this phone and returns its id ("" for empty text). */
    @Synchronized
    fun append(kind: String, text: String, role: String? = null, session: String? = null, meta: JSONObject? = null): String {
        val t = text.trim()
        if (t.isEmpty()) return ""
        val db = writableDatabase
        // The counter outlives deleteAll: a reused id would be ignored by the laptop's mirror (insert-or-ignore).
        val rows = db.rawQuery("SELECT COALESCE(MAX(seq), 0) FROM events WHERE device = ?", arrayOf(device)).use { it.moveToFirst(); it.getLong(0) }
        val seq = maxOf(rows, get("seq")?.toLongOrNull() ?: 0) + 1
        put("seq", seq.toString())
        val id = "$device:$seq"
        db.insertOrThrow("events", null, ContentValues().apply {
            put("id", id); put("device", device); put("seq", seq); put("ts", System.currentTimeMillis() / 1000.0)
            put("kind", kind); put("session", session); put("role", role); put("text", t)
            put("meta", (meta ?: JSONObject()).toString()); put("pending", 0)
        })
        return id
    }

    // ---- sync (authority side) ----------------------------------------------------------------

    /** `GET /memory/pull`: events after `rowid` in this phone's own row order, and the last rowid returned. */
    @Synchronized
    fun eventsAfter(rowid: Long, limit: Int = 500): Pair<List<Event>, Long> {
        var last = rowid
        val out = readableDatabase.rawQuery("SELECT rowid, $cols FROM events WHERE rowid > ? ORDER BY rowid LIMIT ?",
            arrayOf(rowid.toString(), limit.toString())).use { c ->
            buildList { while (c.moveToNext()) { last = c.getLong(0); add(c.event(1)) } }
        }
        return out to last
    }

    /** `POST /memory/push`: events from the laptop (idempotent). Returns how many were new. */
    @Synchronized
    fun ingest(events: List<Event>): Int {
        val db = writableDatabase
        var n = 0
        db.beginTransaction()
        try {
            for (e in events) {
                val r = db.insertWithOnConflict("events", null, ContentValues().apply {
                    put("id", e.id); put("device", e.device); put("seq", e.seq); put("ts", e.ts); put("kind", e.kind)
                    put("session", e.session); put("role", e.role); put("text", e.text); put("meta", e.meta.toString()); put("pending", 0)
                }, SQLiteDatabase.CONFLICT_IGNORE)
                if (r != -1L) n++
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        return n
    }

    /** `GET /memory/status`, with the same keys as the Python store. */
    @Synchronized
    fun stats(): JSONObject {
        val db = readableDatabase
        fun groups(col: String) = JSONObject().also { o ->
            db.rawQuery("SELECT $col, COUNT(*) FROM events GROUP BY $col", null).use { c -> while (c.moveToNext()) o.put(c.getString(0), c.getInt(1)) }
        }
        val total = db.rawQuery("SELECT COUNT(*) FROM events", null).use { it.moveToFirst(); it.getInt(0) }
        return JSONObject().put("path", databaseName).put("role", "authority").put("device", device).put("events", total)
            .put("by_kind", groups("kind")).put("by_device", groups("device")).put("pending", 0).put("vectors", 0)
            .put("embedder", false).put("last_sync", JSONObject.NULL)
    }

    fun put(k: String, v: String) = writableDatabase.execSQL("INSERT OR REPLACE INTO kv (k, v) VALUES (?, ?)", arrayOf(k, v))
    fun get(k: String): String? = readableDatabase.rawQuery("SELECT v FROM kv WHERE k = ?", arrayOf(k)).use { if (it.moveToFirst()) it.getString(0) else null }

    // ---- conversations ------------------------------------------------------------------------

    /** Every conversation, newest first; the title is the session's first user turn. */
    @Synchronized
    fun sessions(): List<SessionSummary> = readableDatabase.rawQuery(
        """SELECT session, MAX(ts), COUNT(*), GROUP_CONCAT(DISTINCT device),
                  (SELECT text FROM events f WHERE f.session = e.session AND f.kind = 'chat' AND f.role = 'user' ORDER BY f.rowid LIMIT 1)
           FROM events e WHERE kind = 'chat' AND session IS NOT NULL GROUP BY session ORDER BY MAX(ts) DESC""", null,
    ).use { c ->
        buildList {
            while (c.moveToNext()) add(SessionSummary(c.getString(0), (c.getString(4) ?: "").take(80), c.getDouble(1), c.getInt(2),
                (c.getString(3) ?: "").split(',').filter { it.isNotEmpty() }.toSet()))
        }
    }

    @Synchronized
    fun chat(session: String): List<Event> = readableDatabase.rawQuery(
        "SELECT $cols FROM events WHERE kind = 'chat' AND session = ? ORDER BY ts, rowid", arrayOf(session),
    ).use { c -> buildList { while (c.moveToNext()) add(c.event()) } }

    @Synchronized
    fun counts(): Map<String, Int> = readableDatabase.rawQuery("SELECT kind, COUNT(*) FROM events GROUP BY kind", null).use { c ->
        buildMap { while (c.moveToNext()) put(c.getString(0), c.getInt(1)) }
    }

    /** Deletes this phone's copy only: the protocol has no deletions, so the laptop's mirror keeps what it pulled. */
    @Synchronized
    fun deleteAll() {
        writableDatabase.delete("events", null, null)
        writableDatabase.delete("vectors", null, null)
        writableDatabase.delete("kv", "k != 'seq'", null)
    }

    // ---- recall -------------------------------------------------------------------------------

    /** Embeds every event that has no vector yet (after writes and syncs). Returns how many were added. */
    fun reindex(): Int {
        val e = embedder ?: return 0
        val missing = synchronized(this) {
            readableDatabase.rawQuery("SELECT e.id, e.text FROM events e LEFT JOIN vectors v ON v.id = e.id WHERE v.id IS NULL", null)
                .use { c -> buildList { while (c.moveToNext()) add(c.getString(0) to c.getString(1)) } }
        }
        var n = 0
        for ((id, text) in missing) {
            val v = runCatching { e.embed(text) }.getOrNull() ?: continue
            val buf = java.nio.ByteBuffer.allocate(v.size * 4).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            v.forEach { buf.putFloat(it) }
            synchronized(this) {
                writableDatabase.execSQL("INSERT OR REPLACE INTO vectors (id, vec) VALUES (?, ?)", arrayOf<Any>(id, buf.array()))
            }
            n++
        }
        return n
    }

    /**
     * Recall as in memory.py: cosine similarity of EmbeddingGemma vectors, facts ranked a little higher, web answers
     * skipped. Without the embedding model, falls back to [keywordSearch].
     */
    fun search(query: String, k: Int = 4, minScore: Double = 0.0, kinds: List<String> = listOf("fact", "doc", "chat")): List<Hit> {
        // Vector thresholds (0.55 recall, 0.93 duplicate) mapped onto the share of query words found.
        val kw = if (minScore >= 0.9) 0.99 else if (minScore > 0) 0.5 else 0.34
        val e = embedder ?: return keywordSearch(query, k, kw, kinds)
        if (query.isBlank()) return emptyList()
        reindex()
        val q = runCatching { e.embed(query, query = true) }.getOrNull() ?: return keywordSearch(query, k, kw, kinds)
        val rows = synchronized(this) {
            readableDatabase.rawQuery(
                "SELECT ${cols.split(", ").joinToString { "e.$it" }}, v.vec FROM events e JOIN vectors v ON v.id = e.id WHERE e.kind IN (${kinds.joinToString(",") { "?" }})",
                kinds.toTypedArray(),
            ).use { c -> buildList { while (c.moveToNext()) add(c.event() to c.getBlob(9)) } }
        }
        return rows.asSequence()
            .filter { !it.first.meta.optBoolean("web") }
            .map { (ev, blob) ->
                val b = java.nio.ByteBuffer.wrap(blob).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                var s = 0.0
                for (i in q.indices) if (b.remaining() >= 4) s += q[i] * b.float
                Hit(ev, s + if (ev.kind == "fact") 0.05 else 0.0)
            }
            .filter { it.score >= minScore }
            .sortedByDescending { it.score }
            .take(k).toList()
    }

    /**
     * Keyword recall over facts and documents (the phone has no embedding model yet; docs/ANDROID.md §5 allows
     * keywords first). Score is the share of the query's words found in the event; web answers are skipped.
     */
    @Synchronized
    fun keywordSearch(query: String, k: Int = 4, minScore: Double = 0.5, kinds: List<String> = listOf("fact", "doc")): List<Hit> {
        val q = words(query)
        if (q.isEmpty()) return emptyList()
        val rows = readableDatabase.rawQuery(
            "SELECT $cols FROM events WHERE kind IN (${kinds.joinToString(",") { "?" }})", kinds.toTypedArray(),
        ).use { c -> buildList { while (c.moveToNext()) add(c.event()) } }
        return rows.asSequence()
            .filter { !it.meta.optBoolean("web") }
            .map { e ->
                val w = words(e.text)
                var score = q.count { it in w }.toDouble() / q.size
                if (e.kind == "fact") score += 0.05
                Hit(e, score)
            }
            .filter { it.score >= minScore && it.score > 0.05 }
            .sortedByDescending { it.score }
            .take(k).toList()
    }

    companion object {
        private val STOP = setOf(
            "the", "and", "for", "are", "was", "were", "what", "where", "when", "who", "whom", "which", "how", "why", "does", "did",
            "can", "could", "would", "should", "will", "you", "your", "user", "user's", "users", "about", "with", "this", "that",
            "from", "have", "has", "had", "tell", "know", "remember", "please", "there", "they", "them", "she", "her", "his", "him",
        )

        /** Lower-case words of three letters or more, without stop words, with a light plural/tense strip. */
        fun words(text: String): Set<String> = Regex("[\\p{L}\\p{N}']{3,}").findAll(text.lowercase()).map { it.value.trim('\'') }
            .filter { it.length >= 3 && it !in STOP }
            .map { it.removeSuffix("'s").removeSuffix("ing").removeSuffix("ed").removeSuffix("es").removeSuffix("s") }
            .filter { it.length >= 2 }.toSet()

        /** Same block as `format_memory`: most relevant first, within a character budget. */
        fun format(hits: List<Hit>, budget: Int = 4000): String {
            val day = SimpleDateFormat("yyyy-MM-dd", Locale.US)
            var used = 0
            return hits.mapNotNull { h ->
                val label = when (h.event.kind) {
                    "fact" -> "remembered"
                    "doc" -> "from " + (h.event.meta.optString("path").substringAfterLast('/').ifEmpty { "document" })
                    "chat" -> "earlier conversation"
                    else -> h.event.kind
                }
                val line = "- ($label, ${day.format(Date((h.event.ts * 1000).toLong()))}) ${h.event.text.trim()}"
                if (used + line.length > budget) null else line.also { used += it.length }
            }.joinToString("\n")
        }

        fun eventsFromJson(a: JSONArray): List<Event> = (0 until a.length()).mapNotNull { runCatching { Event.fromJson(a.getJSONObject(it)) }.getOrNull() }
    }
}
