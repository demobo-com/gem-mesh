"""A client session: node table, router, transcript, and the ask() that the chat loop and the shim share."""
from __future__ import annotations

import sys
import threading
import time
import uuid
from collections.abc import Iterator
from dataclasses import dataclass, field

from meshcore.discovery import NodeTable
from meshcore.engine import LocalEngine
from meshcore.nodes import NodeError
from meshcore.memory import Embedder, MemoryStore, format_memory
from meshcore.network import detect
from meshcore.nodes import LocalNode, NodeInfo
from meshcore.policy import Policy, load_policy
from meshcore.profile import Profile, load_profile
from meshcore.router import Decision, route

DIM, RESET, BOLD, BLUE, AMBER, GREEN = "\033[2m", "\033[0m", "\033[1m", "\033[34m", "\033[33m", "\033[32m"


@dataclass
class Answer:
    text: str
    decision: Decision
    node: NodeInfo | None
    seconds: float
    badge: str


@dataclass
class ClientSession:
    profile: Profile
    policy: Policy
    table: NodeTable
    network_override: str | None = None
    prefer_tier: str | None = None
    think_override: bool | None = None       # /think on|off; None = policy effort per tier
    _vision: object = None                   # an on-device engine that can see images (lazy)
    _class_cache: dict = field(default_factory=dict)
    memory: MemoryStore | None = None
    memory_note: str = ""
    last_memory: str = ""
    session_id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])
    transcript: list[dict] = field(default_factory=list)
    system: str = ("You are a helpful assistant running inside the user's own private mesh. Answer directly and concisely. "
                   "You have a memory on the user's devices: when they tell you something worth keeping, save it with the "
                   "remember tool; earlier facts appear below when relevant, and recall searches them. "
                   "The user's workspace files are available through list_files and read_file. You can also create and "
                   "change files there (text, PDF, images) with write_file, edit_file, pdf_pages, edit_image and make_image; "
                   "the user approves each change, so just call the tool when they ask for a file to be made or changed. "
                   "look_at_image shows you what a photo contains, on the device. "
                   "After a change, tell them in one line what was saved.")

    @classmethod
    def start(cls, role: str | None = None, network: str | None = None, with_local: bool | None = None, quiet: bool = False) -> "ClientSession":
        prof = load_profile(role=role)
        pol = load_policy(prof.policy_path())
        local = None
        want_local = prof.is_local_only() if with_local is None else with_local
        if want_local:
            mp = prof.model_path()
            if not mp.exists():
                print(f"{AMBER}local model missing: {mp}  (mesh --role {prof.role} models pull){RESET}", file=sys.stderr)
            else:
                if not quiet:
                    print(f"{DIM}loading {prof.model} in-process…{RESET}", file=sys.stderr, flush=True)
                eng = LocalEngine(prof.model, mp, max_num_tokens=min(prof.max_num_tokens, 8192), max_sessions=1, cache=prof.cache)
                local = LocalNode(NodeInfo(name="local", device=prof.device, tier=prof.tier, model=prof.model), eng)
        table = NodeTable(mesh=prof.mesh, static_urls=prof.static_nodes, local=local).start()
        sess = cls(profile=prof, policy=pol, table=table, network_override=network)
        if prof.memory in ("authority", "mirror"):
            emb_id = getattr(pol, "embedding", None) or "embeddinggemma-2"
            sess.memory = MemoryStore(prof.memory_path(), prof.device, authority=prof.memory == "authority",
                                      embedder=Embedder(prof.model_path(emb_id)))
            if prof.memory == "authority":
                import socket
                with socket.socket() as probe:
                    busy = probe.connect_ex(("127.0.0.1", prof.node_port)) == 0
                if busy:   # another phone-stand-in process already serves this memory (same file)
                    sess.memory_note = f"memory: authority, already served on :{prof.node_port}"
                else:
                    from meshcore.memory_server import serve_in_background
                    serve_in_background(sess.memory, "0.0.0.0", prof.node_port, mesh=table.security)
                    sess.memory_note = f"memory: authority, serving on :{prof.node_port}"
                    # Announce it the way the Android app will, so the laptop finds the phone with no settings.
                    try:
                        from meshcore.discovery import Advertiser
                        sec = table.security
                        sess._mem_ad = Advertiser(prof.device, prof.tier, prof.model, prof.node_port, mesh=prof.mesh,
                                                  api="memory", base="/memory",
                                                  extra={"tls": "1", "ca": sec.ca_fingerprint()[:16]} if sec else None)
                        sess._mem_ad.start()
                    except Exception:
                        pass
            else:
                sess.memory_note = (f"memory: mirror of {prof.memory_peer}" if prof.memory_peer
                                    else "memory: on this Mac, syncs with your phone when it is on the network")
                threading.Thread(target=sess._sync_loop, daemon=True).start()
        return sess

    def _sync_loop(self) -> None:
        while True:
            self.sync_memory(quiet=True)
            time.sleep(20)

    def memory_peers(self) -> list[tuple[str, str]]:
        """Where the phone's memory may be: the profile's memory_peer first, then phones found over mDNS."""
        out = [("profile", self.profile.memory_peer)] if self.profile.memory_peer else []
        return out + [p for p in self.table.memory_peers() if p[1] != self.profile.memory_peer]

    def sync_memory(self, quiet: bool = False) -> dict | None:
        if not (self.memory and not self.memory.authority):
            return None
        last = None
        for device, url in self.memory_peers():
            try:
                r = self.memory.sync_with(url, client_kwargs=self.table._client_kw)
                who = "" if device == "profile" else f" with {device}"
                self.memory_note = f"memory: mirror, synced{who} {time.strftime('%H:%M:%S')}"
                return r
            except Exception as e:
                last = e
        n = len(self.memory.outbox())
        self.memory_note = (f"memory: on this Mac, syncs with your phone when it is on the network ({n} to sync)" if last is None
                            else f"memory: on this Mac, phone unreachable ({n} to sync)")
        if not quiet:
            return {"error": type(last).__name__ if last else "no phone found", "outbox": n}
        return None

    def recall(self, prompt: str, k: int = 4) -> str:
        if not self.memory:
            return ""
        try:
            hits = self.memory.search(prompt, k=k, min_score=0.55, kinds=("fact", "doc"))
        except Exception:
            return ""
        return format_memory(hits)

    def network(self):
        return detect(self.network_override, self.profile.hotspot_ssids, self.profile.office_ssids)

    def nodes(self) -> list[NodeInfo]:
        return self.table.nodes()

    def mesh_line(self) -> str:
        parts = []
        for n in sorted(self.nodes(), key=lambda n: self.policy.rank(n.tier)):
            ok = n.latency_ms is not None
            parts.append(f"{n.device} {n.tier} {n.model} {'●' if ok else '○'}")
        return "   ".join(parts) if parts else "no nodes reachable"

    def decide(self, prompt: str, context_tokens: int = 0, history: list[dict] | None = None,
               scan_text: str | None = None, need_tokens: int | None = None) -> Decision:
        net = self.network()
        nodes = self.nodes() if net.mode != "offline" else [n for n in self.nodes() if n.local]
        if scan_text is None:
            hist = history if history is not None else self.transcript
            scan_text = "\n".join([str(m.get("content", "")) for m in hist if m.get("role") in ("user", "assistant")] + [prompt])
        clf = self.classify if self.policy.classifier and self.policy.classifier_prompt else None
        return route(prompt, nodes, self.policy, context_tokens=context_tokens, mode=net.mode, scan_text=scan_text,
                     prefer_tier=self.prefer_tier, need_tokens=need_tokens,
                     classifier=(lambda _p: clf(scan_text)) if clf else None)

    def classify(self, text: str) -> tuple[str, str]:
        """Local model privacy label for text the rules passed. Unknown or unavailable counts as sensitive (router)."""
        import hashlib, json as _json, re as _re
        text = text.split("\n\n--- file:")[0][-3000:]
        key = hashlib.sha1(text.encode()).hexdigest()
        if key in self._class_cache:
            return self._class_cache[key]
        nodes = sorted(self.nodes(), key=lambda n: self.policy.rank(n.tier))
        if not nodes:
            return ("unknown", "no model reachable to classify")
        client = self.table.client_for(nodes[0])
        msgs = [{"role": "system", "content": self.policy.classifier_prompt}, {"role": "user", "content": f"CONVERSATION:\n{text}"}]
        try:
            out = "".join(ev["text"] for ev in client.chat_events(msgs, f"classify-{self.session_id}", max_tokens=80, ephemeral=True)
                          if ev["type"] == "text")
            m = _re.search(r"\{.*?\}", out, _re.S)
            d = _json.loads(m.group(0)) if m else {}
            label = str(d.get("label", "unknown")).lower().strip()
            res = (label if label in ("public", "sensitive", "unknown") else "unknown", str(d.get("reason", ""))[:80] + f" · {nodes[0].device}")
        except Exception as ex:
            res = ("unknown", f"classifier failed: {type(ex).__name__}")
        self._class_cache[key] = res
        return res

    def thinking_for(self, node) -> bool:
        if self.think_override is not None:
            return self.think_override
        if self.policy.effort.get(node.tier) == "think":
            return True
        # No workstation around (the demo: a phone and a laptop): heavy work that falls back to the laptop still
        # gets thinking, on models big enough to use it well.
        return (self.policy.effort.get("heavy") == "think" and getattr(self, "_heavy", False)
                and node.tier != "T0" and node.model not in ("gemma4-e2b", "gemma4-e4b"))

    # ---- queue: work that waits for a bigger tier ---------------------------------
    def _queue_db(self):
        import sqlite3
        from meshcore.profile import MESH_HOME
        db = sqlite3.connect(str(MESH_HOME / f"queue-{self.profile.device}.db"), check_same_thread=False)
        db.execute("CREATE TABLE IF NOT EXISTS tasks (id INTEGER PRIMARY KEY AUTOINCREMENT, created REAL, prompt TEXT, needs TEXT, "
                   "status TEXT DEFAULT 'waiting', node TEXT, result TEXT, done REAL)")
        return db

    def enqueue(self, prompt: str, needs: str | None) -> int:
        db = self._queue_db()
        cur = db.execute("INSERT INTO tasks (created, prompt, needs) VALUES (?,?,?)", (time.time(), prompt, needs or "T1"))
        db.commit()
        return int(cur.lastrowid)

    def queue_list(self, include_done: bool = True) -> list[tuple]:
        q = "SELECT id, status, needs, node, substr(prompt,1,80), substr(result,1,160), created FROM tasks"
        q += "" if include_done else " WHERE status='waiting'"
        return self._queue_db().execute(q + " ORDER BY id").fetchall()

    def drain_queue(self, notify=None) -> int:
        """Run waiting tasks whose tier is now reachable. Returns how many ran."""
        db = self._queue_db()
        ran = 0
        for tid, prompt in db.execute("SELECT id, prompt FROM tasks WHERE status='waiting' ORDER BY id").fetchall():
            d = self.decide(prompt, history=[])
            if not d.chosen:
                continue
            db.execute("UPDATE tasks SET status='running', node=? WHERE id=?", (d.chosen.device, tid)); db.commit()
            try:
                ans = self.ask(prompt, history=[])
                db.execute("UPDATE tasks SET status='done', result=?, done=? WHERE id=?", (ans.text, time.time(), tid))
                ran += 1
                if notify:
                    notify(tid, d.chosen, ans)
            except Exception as ex:
                db.execute("UPDATE tasks SET status='waiting', node=NULL WHERE id=?", (tid,))
                if notify:
                    notify(tid, None, f"failed: {type(ex).__name__}")
            db.commit()
        return ran


    # ---- tools for the chats -------------------------------------------------
    def web_allowed(self, prompt: str, history: list[dict]) -> bool:
        """Web access depends on policy and network only. What leaves is a search query or a URL, and each one is
        checked against the privacy rules in run_tool. The strict rule is for inference: a sensitive conversation
        never goes to a model outside the mesh (frontier tier)."""
        return self.policy.web != "never" and self.network().mode != "offline"

    def tool_defs(self, web_ok: bool) -> list[dict]:
        from . import web
        tools = []
        if web_ok:
            tools.append(web.TOOL)
            tools.append({"type": "function", "function": {"name": "fetch", "description": "Read one public web page and return its most relevant text. Use for a link you already have.",
                          "parameters": {"type": "object", "properties": {"url": {"type": "string"}, "question": {"type": "string", "description": "what to look for on the page"}}, "required": ["url"]}}})
        tools.append({"type": "function", "function": {"name": "list_files", "description": (
            "List the files in the user's workspace folder (name, size, first line). Use it when the user asks what files "
            "there are, how many, or refers to a file without its exact name."),
            "parameters": {"type": "object", "properties": {}}}})
        tools.append({"type": "function", "function": {"name": "read_file", "description": "Read one file from the user's workspace folder by name (text, PDF text, or an image's size and colours).",
            "parameters": {"type": "object", "properties": {"name": {"type": "string", "description": "file name, e.g. lisbon-trip.md"}},
                           "required": ["name"]}}})
        if self.memory:
            tools.append({"type": "function", "function": {"name": "remember", "description": (
                "Save a lasting fact about the user to their memory, on their own devices: people in their life, dates, "
                "preferences, plans, decisions, commitments. Call it whenever the user tells you something like that, "
                "even in passing, then answer normally. One short, self-contained sentence per fact."),
                "parameters": {"type": "object", "properties": {"fact": {"type": "string"}}, "required": ["fact"]}}})
            tools.append({"type": "function", "function": {"name": "recall", "description": "Search the user's own memory (past conversations, remembered facts, indexed documents) on their devices.",
                          "parameters": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}}})
        from .files import LOOK_TOOL, TOOL_DEFS
        tools += TOOL_DEFS
        if self.vision_available():
            tools.append(LOOK_TOOL)
        return tools

    VISION_MODELS = ("gemma4-e4b", "gemma4-e2b")

    def vision_available(self) -> bool:
        if self._vision is not None:
            return True
        loc = self.table.local
        if loc is not None and getattr(loc.engine, "vision", False):
            return True
        return any(self.profile.model_path(m).exists() for m in self._vision_candidates())

    def _vision_candidates(self) -> list[str]:
        want = getattr(self.profile, "vision_model", None)
        return ([want] if want else []) + [m for m in self.VISION_MODELS if m != want]

    def vision_engine(self):
        """The phone's own E4B when it can see; otherwise load a small on-device vision model once (the laptop's
        26B has no image encoder). Images never leave the device for this."""
        if self._vision is None:
            loc = self.table.local
            if loc is not None and getattr(loc.engine, "vision", False):
                self._vision = loc.engine
            else:
                mid = next(m for m in self._vision_candidates() if self.profile.model_path(m).exists())
                self._vision = LocalEngine(mid, self.profile.model_path(mid), max_num_tokens=4096, max_sessions=1)
        return self._vision

    def run_tool(self, name: str, args: dict, web_used: list[str], small: bool = False, approve=None) -> str:
        from meshcore.router import classify_rules
        from . import web
        if name in ("web_search", "fetch"):
            target = (args.get("query") or args.get("url") or "").strip()
            if not target:
                return "Error: missing argument."
            if classify_rules(target, self.policy)[0] != "public":
                return ("Blocked: the query contained private information (a client, person, email, figure or path) and was not sent. "
                        "Search again using only general, public terms.")
            if len(web_used) >= 3:
                return "Web limit reached for this question. Answer from what you already have."
            try:
                # A phone-sized model reads less: one page, a short passage.
                if name == "web_search":
                    out = web.search(target, read=2 if small else 3, width=600 if small else 1500)
                else:
                    out = web.best_passage(web.page_text(target), args.get("question") or target, width=1200 if small else 3000)
                web_used.append(f"{name} {target[:60]}")
                return out + ("\n\nAnswer the user from this and name the source. Copy numbers, times and units exactly as written. "
                              "Do not repeat the same search.")
            except Exception as e:
                return f"Failed: {type(e).__name__}"
        if name in ("list_files", "read_file"):
            from . import files as F
            d = F.workspace()
            if not d.is_dir():
                return f"The workspace folder {d} does not exist."
            fs = F.files()
            if name == "list_files":
                rows = [f"- {p.name} ({p.stat().st_size:,} bytes): {F.describe(p)}" for p in fs]
                return f"{len(fs)} file(s) in {d}:\n" + "\n".join(rows)
            match = F.find(args.get("name") or "")
            if not match:
                return f"No file named {args.get('name')!r}. Files: " + ", ".join(p.name for p in fs)
            try:
                return f"{match.name}:\n{F.read_any(match)}"
            except Exception as e:
                return f"Could not read {match.name}: {type(e).__name__}: {e}"
        if name == "look_at_image":
            from . import files as F
            imgs = F.match_images(args.get("name") or "")
            if not imgs:
                return f"No image matching {args.get('name')!r}. Images: " + ", ".join(p.name for p in F.files() if F.kind(p) == "image")
            q = (args.get("question") or "Describe this photo in two sentences.").strip()
            try:
                eng = self.vision_engine()
                seen = eng.look(imgs[0] if len(imgs) == 1 else imgs[:4], q)
            except Exception as e:
                return f"Could not look at the image: {type(e).__name__}: {e}"
            head = f"Looked at {', '.join(p.name for p in imgs[:4])} on this device:\n"
            from PIL import Image as _Im
            located = []
            for p in imgs[:4]:
                try:
                    with _Im.open(p) as im:
                        if "location" in F.photo_meta(im):
                            located.append(p.name)
                except Exception:
                    pass
            if located:
                head = (f"Privacy note: {', '.join(located)} carry the GPS location where they were taken, which goes with "
                        "the files when shared; mention it and offer to remove it first.\n") + head
            return head + seen + (f"\n({len(imgs) - 4} more not looked at)" if len(imgs) > 4 else "")
        from .files import ACTION_TOOLS
        if name in ACTION_TOOLS:
            from . import files as F
            try:
                plan = F.plan_action(name, args)
            except F.FileError as e:
                return f"Not done: {e}"
            except Exception as e:
                return f"Not done: {type(e).__name__}: {e}"
            if approve is None:
                return "Not done: file changes need the user's approval in an open chat. Tell the user what you would change."
            if not approve(plan):
                return "The user declined. Nothing was written. Ask what they would like instead."
            try:
                return plan.apply()
            except Exception as e:
                return f"Failed while saving: {type(e).__name__}: {e}"
        if name == "remember" and self.memory:
            fact = (args.get("fact") or "").strip()
            if not fact:
                return "Error: empty fact."
            known = self.memory.search(fact, k=1, kinds=("fact",))
            if known and known[0].score > 0.93:
                return "Already remembered."
            self.memory.append("fact", fact, session=self.session_id)
            return "Saved."
        if name == "recall" and self.memory:
            hits = self.memory.search(args.get("query") or "", k=6)
            return format_memory(hits) or "Nothing relevant in memory."
        return f"Unknown tool {name}."

    EXTRACT_PROMPT = ("Read the user's message and list lasting facts worth remembering about the user: people in their "
                      "life and how they relate, dates, preferences, plans, decisions, commitments. Write each as one short, "
                      "self-contained sentence in the third person (\"The user's sister Mia lives in Lisbon.\"). Ignore "
                      "questions, requests and anything temporary. Reply with a JSON list of strings only, [] if none.")

    def extract_facts(self, user_text: str, node=None) -> list[str]:
        """Pull lasting facts out of what the user typed and save them. Runs on the node that answered, so it stays in the mesh."""
        import json as _json
        import re as _re
        if not self.memory:
            return []
        text = user_text.split("\n\n--- file:")[0].strip()        # never mine attached documents
        if len(text) < 12 or text.endswith("?") and not _re.search(r"\b(my|I|I'm|I am|we|our)\b", text, _re.I):
            return []
        node = node or next((n for n in self.nodes()), None)
        if node is None:
            return []
        client = self.table.client_for(node)
        msgs = [{"role": "system", "content": self.EXTRACT_PROMPT}, {"role": "user", "content": text[:2000]}]
        try:
            out = "".join(ev["text"] for ev in client.chat_events(msgs, f"extract-{self.session_id}", max_tokens=200, ephemeral=True)
                          if ev["type"] == "text")
            m = _re.search(r"\[.*\]", out, _re.S)
            facts = [str(f).strip() for f in (_json.loads(m.group(0)) if m else []) if str(f).strip()]
        except Exception:
            return []
        saved = []
        for f in facts[:5]:
            known = self.memory.search(f, k=1, kinds=("fact",))
            if known and known[0].score > 0.93:
                continue
            self.memory.append("fact", f, session=self.session_id, meta={"source": "extracted", "node": node.device})
            saved.append(f)
        return saved

    def ask(self, prompt: str, system: str | None = None, history: list[dict] | None = None, on_token=None, max_tokens: int | None = None,
            on_tool=None, approve=None) -> Answer:
        mem = self.recall(prompt)
        sys_text = system or self.system
        if mem:
            sys_text += "\n\n# What you remember about the user (from their own devices)\n" + mem + "\nUse it when relevant; do not mention it otherwise."
        self.last_memory = mem
        msgs = [{"role": "system", "content": sys_text}] + (history if history is not None else self.transcript) + [{"role": "user", "content": prompt}]
        ctx_tokens = sum(len(str(m.get("content", ""))) // 4 for m in msgs[:-1])
        decision = self.decide(prompt, context_tokens=ctx_tokens, history=history,
                               scan_text="\n".join([str(m.get("content", "")) for m in msgs[1:]] + [mem]))
        t0 = time.time()
        self._heavy = any("heavy" in l for l in decision.log)
        if not decision.chosen:
            return Answer("", decision, None, 0.0, f"queue  needs {decision.needs} · nothing reachable")
        client = self.table.client_for(decision.chosen)
        hist = history if history is not None else self.transcript
        web_ok = self.web_allowed(prompt, hist)
        tools = self.tool_defs(web_ok)
        msgs = self._fit(msgs, decision.chosen, tools)
        web_used: list[str] = []
        convo = list(msgs)
        out: list[str] = []
        last_result = None
        node = decision.chosen
        retried = False
        tokens = {"tokens_in": 0, "tokens_out": 0, "tokens_cached": 0}
        estimated = False
        for _ in range(6):
            texts, calls, usage = [], [], {}
            try:
                for ev in client.chat_events(convo, self.session_id, tools=tools or None, max_tokens=max_tokens,
                                             thinking=self.thinking_for(node)):
                    if ev["type"] == "text":
                        texts.append(ev["text"])
                        if on_token:
                            on_token(ev["text"])
                    elif ev["type"] == "tool_calls":
                        calls = ev["calls"]
                    elif ev["type"] == "done":
                        usage = ev.get("usage") or {}
            except NodeError as e:
                # A malformed tool call: read it forgivingly; if it cannot be read, ask once more.
                from meshcore.toolparse import recover_calls
                calls = recover_calls(str(e))
                if not calls and "parse tool call" in str(e) and not retried:
                    retried = True
                    continue
                if not calls:
                    raise
            # Every round is work the node did, counted even when the question then moves to a bigger node.
            if usage.get("prompt_tokens") or usage.get("completion_tokens"):
                tokens["tokens_in"] += usage.get("prompt_tokens", 0)
                tokens["tokens_out"] += usage.get("completion_tokens", 0)
                tokens["tokens_cached"] += (usage.get("prompt_tokens_details") or {}).get("cached_tokens", 0)
            else:       # a node that reports no usage: estimate, as the router does, at 4 characters a token
                estimated = True
                tokens["tokens_in"] += sum(len(str(m.get("content", ""))) for m in convo) // 4
                tokens["tokens_out"] += len("".join(texts) + str(calls if calls else "")) // 4
            out += texts
            if not calls:
                break
            wants_web = any(c["function"]["name"] in ("web_search", "fetch") for c in calls)
            if wants_web and node.local:
                bigger = sorted([n for n in self.nodes() if not n.local], key=lambda n: (self.policy.rank(n.tier), n.load))
                if bigger:
                    # The phone triages; a laptop or workstation reads the web. Restart the question there.
                    node = bigger[0]
                    client = self.table.client_for(node)
                    if on_tool:
                        on_tool("escalate", {"query": f"{node.device} / {node.model}"}, "web reading handed up the mesh")
                    convo, out = list(msgs), []
                    continue
            convo.append({"role": "assistant", "content": "".join(texts), "tool_calls": calls})
            for c in calls:
                import json as _json
                try:
                    args = _json.loads(c["function"]["arguments"] or "{}")
                except ValueError:
                    args = {}
                name = c["function"]["name"]
                result = self.run_tool(name, args, web_used, small=node.local, approve=approve)
                last_result = (name, result)
                if on_tool:
                    on_tool(name, args, result)
                convo.append({"role": "tool", "tool_call_id": c["id"], "content": result})
        text = "".join(out)
        if not text.strip() and last_result and (last_result[0] in ("list_files", "read_file", "recall", "look_at_image")
                                                 or last_result[0] in ("write_file", "edit_file", "pdf_pages", "edit_image", "make_image")):
            # small models sometimes stop after a tool call without answering: show what the tool found
            text = last_result[1]
            if on_token:
                on_token(text)
        secs = time.time() - t0
        left = f"web: {len(web_used)} request(s) left the mesh" if web_used else "0 bytes left the mesh"
        tok = (f"{'~' if estimated else ''}{tokens['tokens_in']:,}→{tokens['tokens_out']:,} tok"
               + (f" ({tokens['tokens_cached']:,} cached)" if tokens["tokens_cached"] else ""))
        badge = f"badge  {node.device} · {node.model}{' · thinking' if self.thinking_for(node) else ''} · {left} · {secs:.1f} s · {tok}"
        if history is None:
            self.transcript += [{"role": "user", "content": prompt}, {"role": "assistant", "content": text}]
        if self.memory:
            for f in self.extract_facts(prompt, node):
                if on_tool:
                    on_tool("remember", {"fact": f}, "Saved.")
            self.memory.append("chat", prompt, role="user", session=self.session_id)
            # The same keys the phone writes (Provenance.meta in the apps), so every device's turns read alike.
            meta = {"node": node.device, "model": node.model, "tier": node.tier, "privacy": decision.privacy,
                    "route": decision.log, "left": left, "seconds": round(secs, 2), "thinking": self.thinking_for(node),
                    **tokens, **({"tokens_est": True} if estimated else {}), **({"web": True} if web_used else {})}
            self.memory.append("chat", text, role="assistant", session=self.session_id, meta=meta)
        return Answer(text, decision, node, secs, badge)

    @staticmethod
    def _fit(msgs: list[dict], node, tools) -> list[dict]:
        """Keep the request well inside the node's window. Small models (E2B/E4B at 4–8K tokens on small Macs) get
        confused, and copy text badly, when a conversation fills their window: first replace files attached in
        earlier turns with a one-line note, then drop the oldest turns. The current message is never cut."""
        import json as _json
        import re as _re
        window = int(getattr(node, "max_num_tokens", None) or 8192)
        budget = int(window * 0.6) - len(_json.dumps(tools or [])) // 4
        est = lambda ms: sum(len(str(m.get("content", ""))) // 4 for m in ms)
        if est(msgs) <= budget:
            return msgs
        out = [dict(m) for m in msgs]
        for m in out[1:-1]:
            if m.get("role") == "user" and "\n\n--- file: " in str(m.get("content", "")):
                head, *files = str(m["content"]).split("\n\n--- file: ")
                names = [f.split(" ---", 1)[0] for f in files]
                m["content"] = head + "\n[attached earlier: " + ", ".join(names) + "; read_file shows it again]"
        while est(out) > budget and len(out) > 3:
            del out[1]                     # oldest turn after the system message
        return out

    def close(self) -> None:
        ad = getattr(self, "_mem_ad", None)
        if ad is not None:
            try:
                ad.stop()
            except Exception:
                pass
        self.table.stop()
