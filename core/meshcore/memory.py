"""Memory: chat turns, facts and document chunks, with EmbeddingGemma vectors, synced inside a user's pair.

One SQLite file per device. Every event has a global id "<device>:<seq>" assigned by the device that wrote it,
so copies merge without conflicts (insert-or-ignore). The phone (or the mobile stand-in) is the authority: it
serves its events over HTTP while it runs. The laptop keeps a mirror: it pulls the authority's events and keeps
its own new events in an outbox until the authority is reachable, then pushes them.

The authority orders events by its own rowid; the mirror remembers the last rowid it pulled ("cursor").

Forgetting is an event too, so it syncs like the rest: kind "forget" with meta {"targets": [event ids]}. A device
that writes or receives one deletes the targets (and their vectors) and remembers their ids in `forgotten`, so a
copy that arrives later, from either side, is not taken in again.
"""
from __future__ import annotations

import json
import math
import re
import sqlite3
import struct
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
  rowid INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT UNIQUE NOT NULL,          -- "<device>:<seq>"
  device TEXT NOT NULL,
  seq INTEGER NOT NULL,
  ts REAL NOT NULL,
  kind TEXT NOT NULL,               -- chat | fact | doc | forget
  session TEXT,
  role TEXT,
  text TEXT NOT NULL,
  meta TEXT,
  pending INTEGER NOT NULL DEFAULT 0   -- mirror only: written here, not yet pushed to the authority
);
CREATE TABLE IF NOT EXISTS vectors (id TEXT PRIMARY KEY, vec BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS forgotten (id TEXT PRIMARY KEY);
"""


def _pack(v: list[float]) -> bytes:
    return struct.pack(f"{len(v)}f", *v)


def _unpack(b: bytes) -> list[float]:
    return list(struct.unpack(f"{len(b) // 4}f", b))


class Embedder:
    """EmbeddingGemma 2 via LiteRT-LM, loaded lazily (0.3 s), normalized vectors."""

    def __init__(self, model_path: Path):
        self.model_path = Path(model_path)
        self._engine = None
        self._lock = threading.Lock()

    @property
    def available(self) -> bool:
        return self.model_path.exists()

    def _get(self):
        if self._engine is None:
            from litert_lm.embedding_engine import EmbeddingEngine
            self._engine = EmbeddingEngine(str(self.model_path))
        return self._engine

    def embed(self, text: str, query: bool = False) -> list[float]:
        from litert_lm.embedding_engine import EmbeddingOptions
        prefix = "task: search result | query: " if query else "title: none | text: "
        with self._lock:
            return list(self._get().compute_embedding(prefix + text[:2000], EmbeddingOptions(normalize=True)).embedding)


@dataclass
class Hit:
    id: str
    kind: str
    text: str
    score: float
    meta: dict
    ts: float


class MemoryStore:
    def __init__(self, path: Path, device: str, authority: bool, embedder: Embedder | None):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.device = device
        self.authority = authority
        self.embedder = embedder if embedder and embedder.available else None
        self._lock = threading.RLock()
        self.db = sqlite3.connect(str(self.path), check_same_thread=False)
        self.db.executescript(SCHEMA)
        self.db.commit()

    # ---- writing ------------------------------------------------------------
    def _next_seq(self) -> int:
        r = self.db.execute("SELECT COALESCE(MAX(seq), 0) FROM events WHERE device = ?", (self.device,)).fetchone()
        return int(r[0]) + 1

    def append(self, kind: str, text: str, role: str | None = None, session: str | None = None, meta: dict | None = None) -> str:
        text = (text or "").strip()
        if not text:
            return ""
        with self._lock:
            seq = self._next_seq()
            eid = f"{self.device}:{seq}"
            self.db.execute("INSERT INTO events (id, device, seq, ts, kind, session, role, text, meta, pending) VALUES (?,?,?,?,?,?,?,?,?,?)",
                            (eid, self.device, seq, time.time(), kind, session, role, text, json.dumps(meta or {}), 0 if self.authority else 1))
            if kind == "forget":
                self._apply_forget((meta or {}).get("targets") or [])
            self.db.commit()
        if kind != "forget":
            self._embed_ids([eid])
        return eid

    def forget(self, ids: list[str], what: str = "") -> str:
        """Forget these events here and, through sync, on every device. `what` labels the forget event."""
        ids = [i for i in dict.fromkeys(ids) if i]
        if not ids:
            return ""
        return self.append("forget", what or f"forgot {len(ids)} item(s)", meta={"targets": ids})

    def _apply_forget(self, targets: list[str]) -> None:
        """Delete the targets (never a forget event) and keep their ids, so they are not ingested again. Caller holds the lock."""
        for t in targets:
            self.db.execute("INSERT OR IGNORE INTO forgotten (id) VALUES (?)", (t,))
            self.db.execute("DELETE FROM events WHERE id = ? AND kind != 'forget'", (t,))
            self.db.execute("DELETE FROM vectors WHERE id = ?", (t,))

    def facts(self) -> list[dict]:
        """Every remembered fact, newest first."""
        with self._lock:
            rows = self.db.execute(f"SELECT {self._COLS} FROM events WHERE kind = 'fact' ORDER BY ts DESC").fetchall()
        return [self._row(r) for r in rows]

    def add_document(self, path: Path, chunk: int = 900, overlap: int = 150) -> int:
        path = Path(path).expanduser()
        text = path.read_text(errors="replace")
        text = re.sub(r"[ \t]+", " ", text)
        n = 0
        i = 0
        while i < len(text):
            part = text[i:i + chunk].strip()
            if part:
                self.append("doc", part, meta={"path": str(path), "offset": i})
                n += 1
            i += chunk - overlap
        return n

    # ---- sync -----------------------------------------------------------------
    def _row(self, r) -> dict:
        return {"id": r[0], "device": r[1], "seq": r[2], "ts": r[3], "kind": r[4], "session": r[5], "role": r[6], "text": r[7], "meta": json.loads(r[8] or "{}")}

    _COLS = "id, device, seq, ts, kind, session, role, text, meta"

    def events_after(self, rowid: int, limit: int = 500) -> tuple[list[dict], int]:
        """Authority side: events with rowid > `rowid`, and the last rowid returned."""
        with self._lock:
            rows = self.db.execute(f"SELECT rowid, {self._COLS} FROM events WHERE rowid > ? ORDER BY rowid LIMIT ?", (rowid, limit)).fetchall()
        return [self._row(r[1:]) for r in rows], (rows[-1][0] if rows else rowid)

    def ingest(self, events: list[dict], pending: int = 0) -> int:
        """Insert events from the other device (idempotent). Returns how many were new. A forget event deletes its
        targets; an event that was forgotten here is not taken in again."""
        new_ids, forgets = [], 0
        with self._lock:
            for e in events:
                if e["kind"] != "forget" and self.db.execute("SELECT 1 FROM forgotten WHERE id = ?", (e["id"],)).fetchone():
                    continue
                cur = self.db.execute(f"INSERT OR IGNORE INTO events ({self._COLS}, pending) VALUES (?,?,?,?,?,?,?,?,?,?)",
                                      (e["id"], e["device"], e["seq"], e["ts"], e["kind"], e.get("session"), e.get("role"), e["text"], json.dumps(e.get("meta") or {}), pending))
                if cur.rowcount:
                    if e["kind"] == "forget":
                        self._apply_forget((e.get("meta") or {}).get("targets") or [])
                        forgets += 1
                    else:
                        new_ids.append(e["id"])
            self.db.commit()
        self._embed_ids(new_ids)
        return len(new_ids) + forgets

    def outbox(self) -> list[dict]:
        with self._lock:
            rows = self.db.execute(f"SELECT {self._COLS} FROM events WHERE pending = 1 ORDER BY rowid").fetchall()
        return [self._row(r) for r in rows]

    def mark_pushed(self, ids: list[str]) -> None:
        with self._lock:
            self.db.executemany("UPDATE events SET pending = 0 WHERE id = ?", [(i,) for i in ids])
            self.db.commit()

    def get(self, k: str, default: str | None = None) -> str | None:
        r = self.db.execute("SELECT v FROM kv WHERE k = ?", (k,)).fetchone()
        return r[0] if r else default

    def put(self, k: str, v: str) -> None:
        with self._lock:
            self.db.execute("INSERT OR REPLACE INTO kv (k, v) VALUES (?, ?)", (k, v))
            self.db.commit()

    def sync_with(self, peer_url: str, timeout: float = 5.0, client_kwargs: dict | None = None) -> dict:
        """Mirror side: push the outbox to the authority, then pull everything new from it.
        `client_kwargs`: a paired mesh's httpx settings (pinned authority, mesh key)."""
        import httpx
        peer_url = peer_url.rstrip("/")
        http = httpx.Client(timeout=timeout, **(client_kwargs or {}))
        out = self.outbox()
        pushed = 0
        if out:
            r = http.post(f"{peer_url}/memory/push", json={"events": out})
            r.raise_for_status()
            self.mark_pushed([e["id"] for e in out])
            pushed = len(out)
        # The cursor is the authority's own row order, so it is kept per authority: a new phone starts at 0.
        # (Before 23 Oct one shared "cursor" was kept; a second phone then looked fully read. Pulling again is safe:
        # ingest ignores events already here.)
        key = f"cursor:{peer_url}"
        cursor = int(self.get(key, "0") or 0)
        pulled = 0
        while True:
            r = http.get(f"{peer_url}/memory/pull", params={"after": cursor})
            r.raise_for_status()
            d = r.json()
            pulled += self.ingest(d["events"])
            if d["last"] == cursor or not d["events"]:
                break
            cursor = d["last"]
            self.put(key, str(cursor))
        self.put("last_sync", str(time.time()))
        indexed = self.reindex()          # catch up on anything a concurrent writer failed to embed
        return {"pushed": pushed, "pulled": pulled, "indexed": indexed}

    # ---- search -----------------------------------------------------------------
    def _embed_ids(self, ids: list[str]) -> None:
        if not self.embedder or not ids:
            return
        for eid in ids:
            r = self.db.execute("SELECT text FROM events WHERE id = ?", (eid,)).fetchone()
            if not r:
                continue
            try:
                v = self.embedder.embed(r[0])
            except Exception:
                continue
            with self._lock:
                self.db.execute("INSERT OR REPLACE INTO vectors (id, vec) VALUES (?, ?)", (eid, _pack(v)))
                self.db.commit()

    def reindex(self) -> int:
        missing = [r[0] for r in self.db.execute("SELECT e.id FROM events e LEFT JOIN vectors v ON v.id = e.id "
                                                 "WHERE v.id IS NULL AND e.kind != 'forget'")]
        self._embed_ids(missing)
        return len(missing)

    def search(self, query: str, k: int = 4, min_score: float = 0.0, kinds: tuple[str, ...] = ("fact", "doc", "chat"),
               exclude_session: str | None = None) -> list[Hit]:
        if not self.embedder or not query.strip():
            return []
        q = self.embedder.embed(query, query=True)
        with self._lock:
            rows = self.db.execute(f"SELECT e.id, e.kind, e.text, e.meta, e.ts, e.session, v.vec FROM events e JOIN vectors v ON v.id = e.id "
                                   f"WHERE e.kind IN ({','.join('?' * len(kinds))})", kinds).fetchall()
        hits = []
        for eid, kind, text, meta, ts, session, vec in rows:
            if exclude_session and session == exclude_session:
                continue
            md = json.loads(meta or "{}")
            if md.get("web"):
                continue          # live web answers go stale; search the web again instead
            v = _unpack(vec)
            score = sum(a * b for a, b in zip(q, v))
            if kind == "fact":
                score += 0.05          # things the user asked to be remembered rank a little higher
            if score >= min_score:
                hits.append(Hit(eid, kind, text, round(score, 3), md, ts))
        hits.sort(key=lambda h: -h.score)
        return hits[:k]

    def stats(self) -> dict:
        with self._lock:
            by_kind = dict(self.db.execute("SELECT kind, COUNT(*) FROM events GROUP BY kind").fetchall())
            by_dev = dict(self.db.execute("SELECT device, COUNT(*) FROM events GROUP BY device").fetchall())
            pending = self.db.execute("SELECT COUNT(*) FROM events WHERE pending = 1").fetchone()[0]
            vectors = self.db.execute("SELECT COUNT(*) FROM vectors").fetchone()[0]
        last = self.get("last_sync")
        return {"path": str(self.path), "role": "authority" if self.authority else "mirror", "events": sum(by_kind.values()),
                "by_kind": by_kind, "by_device": by_dev, "pending": pending, "vectors": vectors,
                "embedder": bool(self.embedder), "last_sync": float(last) if last else None}


def format_memory(hits: list[Hit], budget_chars: int = 4000) -> str:
    """A block for the model's instructions, most relevant first, within a character budget."""
    lines, used = [], 0
    for h in hits:
        when = time.strftime("%Y-%m-%d", time.localtime(h.ts))
        label = {"fact": "remembered", "doc": f"from {Path(h.meta.get('path', 'document')).name}", "chat": "earlier conversation"}.get(h.kind, h.kind)
        line = f"- ({label}, {when}) {h.text.strip()}"
        if used + len(line) > budget_chars:
            break
        lines.append(line)
        used += len(line)
    return "\n".join(lines)
