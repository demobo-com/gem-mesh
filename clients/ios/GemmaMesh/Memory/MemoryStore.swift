import Foundation
import GemmaMeshKit

/// One memory event (PROTOCOL §4). `id` is "<device>:<seq>", global, so copies merge with insert-or-ignore.
struct Event {
    let id: String
    let device: String
    let seq: Int64
    /// Seconds since the epoch, as in the Python store.
    let ts: Double
    /// chat | fact | doc
    let kind: String
    let session: String?
    let role: String?
    let text: String
    let meta: [String: Any]

    func json() -> [String: Any] {
        ["id": id, "device": device, "seq": seq, "ts": ts, "kind": kind, "session": session ?? NSNull(),
         "role": role ?? NSNull(), "text": text, "meta": meta]
    }

    static func from(_ o: [String: Any]) -> Event? {
        guard let id = o["id"] as? String, let device = o["device"] as? String, let seq = (o["seq"] as? NSNumber)?.int64Value,
              let ts = (o["ts"] as? NSNumber)?.doubleValue, let kind = o["kind"] as? String, let text = o["text"] as? String else { return nil }
        let session = (o["session"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let role = (o["role"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Event(id: id, device: device, seq: seq, ts: ts, kind: kind, session: session, role: role, text: text,
                     meta: o["meta"] as? [String: Any] ?? [:])
    }
}

/// A conversation: the chat events of one session, from this phone or from the laptop's mirror.
struct SessionSummary: Identifiable, Equatable {
    let session: String
    let title: String
    let updated: Double
    let turns: Int
    let devices: Set<String>
    var id: String { session }
}

struct Hit {
    let event: Event
    let score: Double
}

struct QueuedTask: Identifiable, Equatable {
    let id: Int64
    let session: String?
    let prompt: String
    let needs: String
    let status: String
    let node: String?
}

/// The user's memory on the phone: chat turns, facts and document chunks. Port of `core/meshcore/memory.py` with the
/// same `events` schema (as MemoryStore.kt on Android); the phone is the authority (PROTOCOL §4), so nothing here is
/// ever pending. The laptop's mirror pushes its own events here and pulls ours through MemoryServer. Vectors are not
/// synced (each device embeds for itself); until EmbeddingGemma is on the phone, recall is by keywords.
final class MemoryStore: @unchecked Sendable {
    let device: String
    let path: URL
    private let db: SQLite
    private let lock = NSRecursiveLock()

    /// Set once EmbeddingGemma is on the phone; until then recall is by keywords.
    var embedder: Embedder?

    init(device: String, directory: URL) throws {
        self.device = device
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("memory.db")
        db = try SQLite(path: path.path)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS events (
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
              pending INTEGER NOT NULL DEFAULT 0)
            """)
        try db.exec("CREATE TABLE IF NOT EXISTS vectors (id TEXT PRIMARY KEY, vec BLOB NOT NULL)")
        try db.exec("CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT)")
        // Ids of forgotten events (PROTOCOL §4): a copy that arrives again from the laptop is not taken back.
        try db.exec("CREATE TABLE IF NOT EXISTS forgotten (id TEXT PRIMARY KEY)")
        try db.exec("CREATE INDEX IF NOT EXISTS events_by_session ON events(session, rowid)")
        // Work waiting for a bigger tier (session.py's queue database); local to the phone, never synced.
        try db.exec("""
            CREATE TABLE IF NOT EXISTS tasks (
              id INTEGER PRIMARY KEY AUTOINCREMENT, created REAL, session TEXT, prompt TEXT, needs TEXT,
              status TEXT DEFAULT 'waiting', node TEXT, result TEXT, done REAL)
            """)
    }

    private func locked<T>(_ f: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try f()
    }

    private static let cols = "id, device, seq, ts, kind, session, role, text, meta"
    private static let eventCols = "e.id, e.device, e.seq, e.ts, e.kind, e.session, e.role, e.text, e.meta"

    private static func event(_ r: SQLite.Row, _ o: Int32 = 0) -> Event {
        Event(id: r.string(o) ?? "", device: r.string(o + 1) ?? "", seq: r.int(o + 2), ts: r.double(o + 3), kind: r.string(o + 4) ?? "",
              session: r.string(o + 5), role: r.string(o + 6), text: r.string(o + 7) ?? "", meta: JSON.object(r.string(o + 8) ?? "{}") ?? [:])
    }

    // ---- writing ------------------------------------------------------------------------------

    /// Appends an event written on this phone and returns its id ("" for empty text).
    @discardableResult
    func append(_ kind: String, _ text: String, role: String? = nil, session: String? = nil, meta: [String: Any] = [:]) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        return locked {
            // The counter outlives deleteAll: a reused id would be ignored by the laptop's mirror (insert-or-ignore).
            let rows: Int64 = (try? db.scalar("SELECT COALESCE(MAX(seq), 0) FROM events WHERE device = ?", [device])) ?? 0
            let saved: [String] = (try? db.query("SELECT v FROM kv WHERE k = 'seq'", []) { r -> String in r.string(0) ?? "" }) ?? []
            let kept: Int64 = Int64(saved.first ?? "") ?? 0
            let seq = max(rows, kept) + 1
            try? db.exec("INSERT OR REPLACE INTO kv (k, v) VALUES ('seq', ?)", [String(seq)])
            let id = "\(device):\(seq)"
            try? db.exec("INSERT INTO events (id, device, seq, ts, kind, session, role, text, meta, pending) VALUES (?,?,?,?,?,?,?,?,?,0)",
                         [id, device, seq, Date().timeIntervalSince1970, kind, session, role, t, JSON.string(meta)])
            if kind == "forget" { applyForget(meta["targets"] as? [String] ?? []) }
            return id
        }
    }

    /// Forgets these events here and, through sync, on the laptop: a "forget" event naming them (PROTOCOL §4).
    @discardableResult
    func forget(_ ids: [String], _ what: String) -> String {
        var seen = Set<String>()
        let targets = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        if targets.isEmpty { return "" }
        return append("forget", what, meta: ["targets": targets])
    }

    /// Deletes the targets (never a forget event) and their vectors, and keeps their ids. Caller holds the lock.
    private func applyForget(_ targets: [String]) {
        for t in targets {
            _ = try? db.exec("INSERT OR IGNORE INTO forgotten (id) VALUES (?)", [t])
            _ = try? db.exec("DELETE FROM events WHERE id = ? AND kind != 'forget'", [t])
            _ = try? db.exec("DELETE FROM vectors WHERE id = ?", [t])
        }
    }

    // ---- sync (authority side) ----------------------------------------------------------------

    /// `GET /memory/pull`: events after `rowid` in this phone's own row order, and the last rowid returned.
    func events(after rowid: Int64, limit: Int = 500) -> ([Event], Int64) {
        locked {
            let rows = (try? db.query("SELECT rowid, \(MemoryStore.cols) FROM events WHERE rowid > ? ORDER BY rowid LIMIT ?", [rowid, limit]) {
                ($0.int(0), MemoryStore.event($0, 1))
            }) ?? []
            return (rows.map { $0.1 }, rows.last?.0 ?? rowid)
        }
    }

    /// `POST /memory/push`: events from the laptop (idempotent). Returns how many were new. A forget event deletes
    /// its targets; an event forgotten here is not taken in again.
    func ingest(_ events: [Event]) -> Int {
        locked {
            var n = 0
            try? db.transaction {
                for e in events {
                    if e.kind != "forget", ((try? db.scalar("SELECT COUNT(*) FROM forgotten WHERE id = ?", [e.id])) ?? 0) > 0 { continue }
                    let added = (try? db.exec("INSERT OR IGNORE INTO events (id, device, seq, ts, kind, session, role, text, meta, pending) VALUES (?,?,?,?,?,?,?,?,?,0)",
                                              [e.id, e.device, e.seq, e.ts, e.kind, e.session, e.role, e.text, JSON.string(e.meta)])) ?? 0
                    if added > 0, e.kind == "forget" { applyForget(e.meta["targets"] as? [String] ?? []) }
                    n += added
                }
            }
            return n
        }
    }

    /// `GET /memory/status`, with the same keys as the Python store.
    func stats() -> [String: Any] {
        locked {
            func groups(_ col: String) -> [String: Int] {
                Dictionary(uniqueKeysWithValues: (try? db.query("SELECT \(col), COUNT(*) FROM events GROUP BY \(col)") { ($0.string(0) ?? "", Int($0.int(1))) }) ?? [])
            }
            let vectors = (try? db.scalar("SELECT COUNT(*) FROM vectors")) ?? 0
            return ["path": path.lastPathComponent, "role": "authority", "device": device,
                    "events": (try? db.scalar("SELECT COUNT(*) FROM events")) ?? 0,
                    "by_kind": groups("kind"), "by_device": groups("device"), "pending": 0, "vectors": vectors,
                    "embedder": embedder != nil, "last_sync": NSNull()]
        }
    }

    // ---- conversations ------------------------------------------------------------------------

    /// Every conversation, newest first; the title is the session's first user turn.
    func sessions() -> [SessionSummary] {
        locked {
            (try? db.query("""
                SELECT session, MAX(ts), COUNT(*), GROUP_CONCAT(DISTINCT device),
                       (SELECT text FROM events f WHERE f.session = e.session AND f.kind = 'chat' AND f.role = 'user' ORDER BY f.rowid LIMIT 1)
                FROM events e WHERE kind = 'chat' AND session IS NOT NULL GROUP BY session ORDER BY MAX(ts) DESC
                """) { r in
                SessionSummary(session: r.string(0) ?? "", title: String((r.string(4) ?? "").prefix(80)), updated: r.double(1),
                               turns: Int(r.int(2)), devices: Set((r.string(3) ?? "").split(separator: ",").map(String.init)))
            }) ?? []
        }
    }

    /// Every device's chat turns since `ts`, oldest first: what the Mesh page counts.
    func chats(since ts: Double) -> [Event] {
        locked { (try? db.query("SELECT \(MemoryStore.cols) FROM events WHERE kind = 'chat' AND ts >= ? ORDER BY ts, rowid", [ts]) { MemoryStore.event($0) }) ?? [] }
    }

    func chat(_ session: String) -> [Event] {
        locked { (try? db.query("SELECT \(MemoryStore.cols) FROM events WHERE kind = 'chat' AND session = ? ORDER BY ts, rowid", [session]) { MemoryStore.event($0) }) ?? [] }
    }

    func counts() -> [String: Int] {
        locked { Dictionary(uniqueKeysWithValues: (try? db.query("SELECT kind, COUNT(*) FROM events GROUP BY kind") { ($0.string(0) ?? "", Int($0.int(1))) }) ?? []) }
    }

    // ---- what memory holds --------------------------------------------------------------------

    /// Remembered facts, newest first: said by the user (`remember`) or extracted from a conversation.
    func facts() -> [Event] {
        locked { (try? db.query("SELECT \(MemoryStore.cols) FROM events WHERE kind = 'fact' ORDER BY ts DESC, rowid DESC") { MemoryStore.event($0) }) ?? [] }
    }

    /// Indexed documents (the Mac's `/index`), one entry per file: its name, chunk ids, and when it was added.
    func documents() -> [(name: String, ids: [String], ts: Double, device: String)] {
        let chunks = locked { (try? db.query("SELECT \(MemoryStore.cols) FROM events WHERE kind = 'doc' ORDER BY rowid") { MemoryStore.event($0) }) ?? [] }
        var order: [String] = []
        var files: [String: (ids: [String], ts: Double, device: String)] = [:]
        for c in chunks {
            let name = ((c.meta["path"] as? String) ?? "document").components(separatedBy: "/").last ?? "document"
            if files[name] == nil { order.append(name); files[name] = ([], c.ts, c.device) }
            files[name]!.ids.append(c.id)
        }
        return order.map { (name: $0, ids: files[$0]!.ids, ts: files[$0]!.ts, device: files[$0]!.device) }.sorted { $0.ts > $1.ts }
    }

    /// The ids of a conversation's turns, to forget it whole.
    func sessionIds(_ session: String) -> [String] {
        locked { (try? db.query("SELECT id FROM events WHERE kind = 'chat' AND session = ?", [session]) { $0.string(0) ?? "" }) ?? [] }
    }

    /// Forgets everything, here and on the laptop: one forget event naming every event (the forgets stay, so the
    /// laptop still pulls them).
    func deleteAll() {
        let ids = locked { (try? db.query("SELECT id FROM events WHERE kind != 'forget'") { $0.string(0) ?? "" }) ?? [] }
        forget(ids, "forgot everything (\(ids.count) items)")
        locked { _ = try? db.exec("DELETE FROM vectors") }
    }

    // ---- queue --------------------------------------------------------------------------------

    func enqueue(prompt: String, needs: String, session: String) -> Int64 {
        locked {
            try? db.exec("INSERT INTO tasks (created, session, prompt, needs) VALUES (?, ?, ?, ?)", [Date().timeIntervalSince1970, session, prompt, needs])
            return db.lastRowId
        }
    }

    func tasks() -> [QueuedTask] {
        locked {
            (try? db.query("SELECT id, session, prompt, needs, status, node FROM tasks ORDER BY id") { r in
                QueuedTask(id: r.int(0), session: r.string(1), prompt: r.string(2) ?? "", needs: r.string(3) ?? "T1",
                           status: r.string(4) ?? "waiting", node: r.string(5))
            }) ?? []
        }
    }

    func setTask(_ id: Int64, status: String, node: String?, result: String? = nil) {
        locked {
            try? db.exec("UPDATE tasks SET status = ?, node = ?, result = ?, done = ? WHERE id = ?",
                         [status, node, result, status == "done" ? Date().timeIntervalSince1970 : nil, id])
        }
    }

    func clearWaiting() { locked { _ = try? db.exec("DELETE FROM tasks WHERE status = 'waiting'") } }

    // ---- recall -------------------------------------------------------------------------------

    /// Embeds events that have no vector yet (after writes and syncs), newest first, at most `limit` of them.
    /// Returns how many were added.
    @discardableResult
    func reindex(limit: Int = Int.max) async -> Int {
        guard let e = embedder else { return 0 }
        let missing = locked {
            (try? db.query("SELECT e.id, e.text FROM events e LEFT JOIN vectors v ON v.id = e.id WHERE v.id IS NULL AND e.kind != 'forget' ORDER BY e.rowid DESC LIMIT ?",
                           [min(limit, Int(Int32.max))]) { ($0.string(0) ?? "", $0.string(1) ?? "") }) ?? []
        }
        var n = 0
        for (id, text) in missing {
            guard let v = try? await e.embed(text) else { continue }
            var blob = Data(capacity: v.count * 4)
            for f in v { withUnsafeBytes(of: f.bitPattern.littleEndian) { blob.append(contentsOf: $0) } }
            locked { _ = try? db.exec("INSERT OR REPLACE INTO vectors (id, vec) VALUES (?, ?)", [id, blob]) }
            n += 1
        }
        return n
    }

    /// Recall as in memory.py: cosine similarity of EmbeddingGemma vectors, facts ranked a little higher, web answers
    /// skipped. Without the embedding model, falls back to keyword recall.
    func search(_ query: String, k: Int = 4, minScore: Double = 0, kinds: [String] = ["fact", "doc", "chat"]) async -> [Hit] {
        // Vector thresholds (0.55 recall, 0.93 duplicate) mapped onto the share of query words found.
        let kw = minScore >= 0.9 ? 0.99 : (minScore > 0 ? 0.5 : 0.34)
        guard let e = embedder else { return keywordSearch(query, k: k, minScore: kw, kinds: kinds) }
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        // The newest few (a fact just said, a sync just pushed) now; the backlog is the background reindex's job.
        await reindex(limit: 16)
        guard let q = try? await e.embed(query, query: true) else { return keywordSearch(query, k: k, minScore: kw, kinds: kinds) }
        let marks = kinds.map { _ in "?" }.joined(separator: ",")
        let rows: [(Event, Data)] = locked {
            (try? db.query("SELECT \(MemoryStore.eventCols), v.vec FROM events e JOIN vectors v ON v.id = e.id WHERE e.kind IN (\(marks))", kinds.map { $0 as Any? }) {
                (MemoryStore.event($0), $0.blob(9) ?? Data())
            }) ?? []
        }
        return rows.filter { ($0.0.meta["web"] as? Bool) != true }.map { pair -> Hit in
            let (ev, blob) = pair
            var s = 0.0
            blob.withUnsafeBytes { raw in
                let n = min(q.count, raw.count / 4)
                for i in 0..<n {
                    let bits = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                    s += Double(q[i]) * Double(Float(bitPattern: UInt32(littleEndian: bits)))
                }
            }
            return Hit(event: ev, score: s + (ev.kind == "fact" ? 0.05 : 0))
        }.filter { $0.score >= minScore }.sorted { $0.score > $1.score }.prefix(k).map { $0 }
    }

    /// Keyword recall: the share of the query's words found in the event; web answers are skipped.
    func keywordSearch(_ query: String, k: Int = 4, minScore: Double = 0.5, kinds: [String] = ["fact", "doc"]) -> [Hit] {
        let q = MemoryText.words(query)
        if q.isEmpty { return [] }
        let marks = kinds.map { _ in "?" }.joined(separator: ",")
        let rows = locked { (try? db.query("SELECT \(MemoryStore.cols) FROM events WHERE kind IN (\(marks))", kinds.map { $0 as Any? }) { MemoryStore.event($0) }) ?? [] }
        return rows.filter { ($0.meta["web"] as? Bool) != true }.map { e in
            Hit(event: e, score: MemoryText.score(query: q, text: e.text) + (e.kind == "fact" ? 0.05 : 0))
        }.filter { $0.score >= minScore && $0.score > 0.05 }.sorted { $0.score > $1.score }.prefix(k).map { $0 }
    }

    /// Same block as `format_memory`: most relevant first, within a character budget.
    static func format(_ hits: [Hit], budget: Int = 4000) -> String {
        var used = 0
        var lines: [String] = []
        for h in hits {
            let line = MemoryText.line(kind: h.event.kind, path: h.event.meta["path"] as? String, ts: h.event.ts, text: h.event.text)
            if used + line.count > budget { continue }
            used += line.count
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
