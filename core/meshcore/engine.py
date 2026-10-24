"""In-process LiteRT-LM engine with per-session conversations, tool calling and KV reuse.

Used by meshnode (serving over HTTP) and by the mobile client (the phone runs its model in-process,
so the mock does too).

Message format everywhere above the engine is OpenAI chat format:
  {"role": "system"|"user"|"assistant"|"tool", "content": str|parts,
   "tool_calls": [{"id", "type": "function", "function": {"name", "arguments": json-str}}],  # assistant
   "tool_call_id": str}                                                                      # tool
Tools are OpenAI function definitions: {"type": "function", "function": {"name", "description", "parameters"}}.

Sessions: a client resends its whole history every turn. If a live session already holds the history
up to the last assistant turn, only the new tail (user text or tool results) is prefilled. Otherwise the
conversation is rebuilt from the history. One generation at a time per engine; idle and excess sessions
are evicted; failed requests drop their session.
"""
from __future__ import annotations

import hashlib
import json
import queue
import threading
import time
import uuid
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import litert_lm
from litert_lm import interfaces

Message = dict[str, Any]


class EngineError(Exception):
    def __init__(self, message: str, status: int = 500):
        super().__init__(message)
        self.status = status


def text_of(content: Any) -> str:
    """OpenAI-style content (str or parts list) to plain text."""
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(p.get("text", "") if isinstance(p, dict) and p.get("type", "text") == "text" else
                       (p if isinstance(p, str) else "") for p in content)
    return str(content)


class ProxyTool(litert_lm.Tool):
    """A client-side tool: declared to the model, never executed here (the client runs it)."""

    def __init__(self, definition: dict):
        self.definition = definition

    def get_tool_description(self) -> dict:
        return self.definition

    def execute(self, param):  # pragma: no cover - automatic tool calling is off
        raise NotImplementedError("client-side tool")


def _canon_args(args: Any) -> str:
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except json.JSONDecodeError:
            return args
    return json.dumps(args, sort_keys=True, ensure_ascii=False)


def _fp(m: Message) -> str:
    """Fingerprint of a message for history matching: role, stripped text, tool calls, tool_call_id.

    Tool calls are identified by the id the engine minted when the call carries one: clients echo the id
    unchanged but may rewrite the arguments (Claude Code adds defaults such as "replace_all": false).
    """
    calls = [(c.get("function", {}).get("name"), c.get("id") or _canon_args(c.get("function", {}).get("arguments")))
             for c in (m.get("tool_calls") or [])]
    key = {"r": m.get("role"), "t": text_of(m.get("content")).strip(), "c": calls, "i": m.get("tool_call_id")}
    return hashlib.sha1(json.dumps(key, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def _to_litert(msgs: list[Message], names: dict[str, str]) -> list[Message]:
    """OpenAI messages to LiteRT-LM conversation messages."""
    out: list[Message] = []
    for m in msgs:
        role = m.get("role")
        if role == "tool":
            cid = m.get("tool_call_id")
            out.append({"role": "tool", "content": [{"type": "tool_response", "name": names.get(cid, cid or "tool"),
                                                      "response": text_of(m.get("content"))}]})
        elif role == "assistant" and m.get("tool_calls"):
            calls = []
            for c in m["tool_calls"]:
                f = c.get("function", {})
                a = f.get("arguments", {})
                if isinstance(a, str):
                    try:
                        a = json.loads(a)
                    except json.JSONDecodeError:
                        a = {}
                calls.append({"type": "function", "function": {"name": f.get("name"), "arguments": a}})
            msg: Message = {"role": "assistant", "tool_calls": calls}
            t = text_of(m.get("content"))
            if t:
                msg["content"] = t
            out.append(msg)
        else:
            out.append({"role": role, "content": text_of(m.get("content"))})
    return out


def _collapse_tail(msgs: list[Message]) -> Message:
    """LiteRT-LM takes one message per turn. Tool results merge into one tool message (several tool_response
    parts); user text that follows them (e.g. a system-reminder note) is appended to the last result; with no
    tool results, user texts are joined."""
    tools = [m for m in msgs if m["role"] == "tool"]
    texts = [text_of(m.get("content")) for m in msgs if m["role"] != "tool"]
    if tools:
        parts = [p for m in tools for p in m["content"]]
        if texts:
            parts[-1] = dict(parts[-1], response=f"{parts[-1]['response']}\n\n" + "\n\n".join(texts))
        return {"role": "tool", "content": parts}
    return {"role": "user", "content": "\n\n".join(texts)}


@dataclass
class Session:
    id: str
    conv: Any
    key: str                      # system + tool names fingerprint
    fps: list[str]                # fingerprints of messages the conversation holds
    turns: int = 0
    created: float = field(default_factory=time.time)
    last_used: float = field(default_factory=time.time)


class LocalEngine:
    CACHE_MODES = {"no": ":nocache", "memory": ":memory", "disk": ""}
    THINK_BUDGET = 1024           # reasoning tokens allowed before the answer when thinking is on

    def __init__(self, model_id: str, model_path: Path, max_num_tokens: int = 32768,
                 backend: str = "gpu", max_sessions: int = 2, idle_seconds: int = 600, cache: str = "no"):
        self.model_id = model_id
        self.model_path = Path(model_path)
        if not self.model_path.exists():
            raise FileNotFoundError(f"model file not found: {self.model_path}")
        self.max_num_tokens = max_num_tokens
        self.max_sessions = max_sessions
        self.idle_seconds = idle_seconds
        self.cache = cache
        self.lock_timeout = 120.0
        self._lock = threading.Lock()
        self._sessions: dict[str, Session] = {}
        self.generating = False
        self.counters = {"requests": 0, "reused": 0, "rebuilt": 0, "errors": 0, "tokens_in": 0, "tokens_out": 0, "tokens_cached": 0}
        t0 = time.time()
        be = interfaces.Backend.GPU() if backend == "gpu" else interfaces.Backend.CPU()
        # Ring buffers for Gemma 4's sliding-window layers: without them each local-attention layer gets a
        # full-length KV buffer (31B on the 5090: 32.1 GB → 21.2 GB with them, measured on an RTX 5090). The cost is
        # no instant rewind of the local-attention cache, which append-only sessions never need.
        # cache "no" matches `litert-lm --cache no`: no GPU weight cache files next to the model.
        # Vision: the E2B/E4B builds carry an image encoder (the 12B and 26B builds do not). Turn it on when present.
        # Benchmark counters give each generation's exact prefill and decode token counts (the usage we report).
        self.vision = False
        try:
            with litert_lm.ModelInfo(str(self.model_path)) as mi:
                self.vision = bool(mi.input_modalities.vision)
        except Exception:
            pass
        self._vision_kw = {"vision_backend": interfaces.Backend.GPU() if backend == "gpu" else interfaces.Backend.CPU(),
                           "max_num_images": 4} if self.vision else {}
        self.engine = litert_lm.Engine(model_path=str(self.model_path), backend=be, max_num_tokens=max_num_tokens,
                                       cache_dir=self.CACHE_MODES.get(str(cache), ":nocache"),
                                       use_ringbuffers_local_attention=True, enable_benchmark=True, **self._vision_kw)
        self.init_seconds = time.time() - t0
        self.backend = be
        self.resets = 0

    def _reset_engine(self, why: str) -> None:
        """Rebuild the LiteRT-LM engine after an internal error: a failed or cancelled generation can leave it
        returning fragments of earlier input instead of generating (seen once on the MacBook, 22 Oct)."""
        import logging
        log = logging.getLogger("meshcore.engine")
        log.error("engine reset after error: %s", why)
        print(f"meshnode  engine reset after error: {why}", flush=True)
        for sid in list(self._sessions):
            self._close(sid)
        try:
            self.engine.close()
        except Exception:
            pass
        self.engine = litert_lm.Engine(model_path=str(self.model_path), backend=self.backend, max_num_tokens=self.max_num_tokens,
                                       cache_dir=self.CACHE_MODES.get(str(self.cache), ":nocache"),
                                       use_ringbuffers_local_attention=True, enable_benchmark=True, **self._vision_kw)
        self.resets += 1

    def look(self, image_path, question: str, max_tokens: int = 300) -> str:
        """Answer a question about one image, or up to four (a list, labelled by file name, so they can be compared),
        in a throwaway conversation on this device. Vision models only."""
        if not self.vision:
            raise EngineError(f"{self.model_id} has no image encoder", 400)
        if not self._lock.acquire(timeout=self.lock_timeout):
            raise EngineError("engine busy", 503)
        try:
            self.generating = True
            with self.engine.create_conversation() as c:
                paths = image_path if isinstance(image_path, (list, tuple)) else [image_path]
                content = []
                for i, ip in enumerate(paths[:4], 1):
                    if len(paths) > 1:
                        content.append({"type": "text", "text": f"Image {i}: {Path(ip).name}"})
                    content.append({"type": "image", "path": str(Path(ip).resolve())})
                content.append({"type": "text", "text": (question.strip() or "Describe this image.")
                                + (" Refer to each image by its file name." if len(paths) > 1 else "")})
                r = c.send_message({"role": "user", "content": content})
            text = r if isinstance(r, str) else (r.get("content") if isinstance(r, dict) else str(r))
            if isinstance(text, list):
                text = "".join(x.get("text", "") for x in text if isinstance(x, dict))
            return str(text).strip()
        finally:
            self.generating = False
            self._lock.release()

    # ---- sessions ---------------------------------------------------------
    def _close(self, sid: str) -> None:
        s = self._sessions.pop(sid, None)
        if s is not None:
            try:
                s.conv.close()
            except Exception:
                pass

    def _evict(self, keep: str | None = None) -> None:
        now = time.time()
        for sid, s in list(self._sessions.items()):
            if sid != keep and now - s.last_used > self.idle_seconds:
                self._close(sid)
        while len(self._sessions) > self.max_sessions:
            victims = [s for s in self._sessions.values() if s.id != keep]
            if not victims:
                break
            self._close(min(victims, key=lambda s: s.last_used).id)

    def stats(self) -> dict:
        n = len(self._sessions)
        return {"model": self.model_id, "sessions": n, "max_sessions": self.max_sessions,
                "generating": self.generating, "max_num_tokens": self.max_num_tokens,
                "load": round(min(1.0, (min(n, self.max_sessions) * 0.5 + (0.5 if self.generating else 0)) / max(1, self.max_sessions)), 2),
                "init_seconds": round(self.init_seconds, 1), "resets": getattr(self, "resets", 0), **self.counters}

    # ---- usage --------------------------------------------------------------
    @staticmethod
    def _kv_tokens(conv) -> int | None:
        try:
            return conv.token_count
        except Exception:
            return None

    def _usage(self, conv, before: int | None, text: str, calls: list[dict]) -> dict:
        """OpenAI usage for one generation. prompt_tokens is the whole prompt; the part a reused session already held
        in its KV cache is prompt_tokens_details.cached_tokens, so prompt - cached + completion is the work this node
        did. Benchmark counters give the exact prefill and decode counts; without them the KV growth is split by
        tokenizing the reply. {} when neither is available."""
        cached = before or 0
        try:
            b = conv.get_benchmark_info()
            prefill, decode = b.last_prefill_token_count, b.last_decode_token_count
        except Exception:
            try:
                grown = conv.token_count - cached
                out = text + "".join(c["function"]["name"] + c["function"]["arguments"] for c in calls)
                decode = min(grown, len(self.engine.tokenize(out)))
                prefill = grown - decode
            except Exception:
                return {}
        self.counters["tokens_in"] += cached + prefill
        self.counters["tokens_out"] += decode
        self.counters["tokens_cached"] += cached
        return {"prompt_tokens": cached + prefill, "completion_tokens": decode, "total_tokens": cached + prefill + decode,
                "prompt_tokens_details": {"cached_tokens": cached}}

    # ---- chat ---------------------------------------------------------------
    def chat_events(self, messages: list[Message], session_id: str, tools: list[dict] | None = None,
                    max_output_tokens: int | None = None, thinking: bool = False,
                    ephemeral: bool = False) -> Iterator[dict]:
        """Yield {"type": "text", "text"} chunks, then {"type": "tool_calls", "calls": [...]} if any,
        then {"type": "done", "finish": "stop"|"tool_calls", "reused": bool, "usage": {OpenAI usage} or {}}.

        `ephemeral` sessions are closed after the reply (side requests that should not evict real work).
        Raises EngineError(status=400) for bad or over-window input, EngineError(500) otherwise.
        """
        system = "\n\n".join(text_of(m.get("content")) for m in messages if m.get("role") == "system").strip()
        convo = [m for m in messages if m.get("role") in ("user", "assistant", "tool")]
        if not convo or convo[-1].get("role") == "assistant":
            raise EngineError("the last message must be from the user or a tool result", 400)
        last_asst = max((i for i, m in enumerate(convo) if m.get("role") == "assistant"), default=-1)
        head, tail = convo[:last_asst + 1], convo[last_asst + 1:]
        names = {c.get("id"): c.get("function", {}).get("name") for m in convo for c in (m.get("tool_calls") or []) if c.get("id")}
        tools = tools or []
        key = hashlib.sha1(json.dumps([system, [t.get("function", {}).get("name") for t in tools], bool(thinking)]).encode()).hexdigest()
        head_fps = [_fp(m) for m in head]

        q: queue.Queue = queue.Queue()
        cancel = threading.Event()

        def work() -> None:
            """Runs the generation on its own thread, so an abandoned client can never hold the engine lock."""
            if not self._lock.acquire(timeout=self.lock_timeout):
                q.put(("err", EngineError(f"node busy: another generation has held the engine for over {self.lock_timeout:.0f} s", 503)))
                q.put(("end", None))
                return
            s = None
            try:
                self.counters["requests"] += 1
                s = self._sessions.get(session_id)
                reused = s is not None and s.key == key and s.fps == head_fps
                if not reused:
                    if s is not None:
                        self._close(session_id)
                    preface = ([{"role": "system", "content": system}] if system else []) + _to_litert(head, names)
                    conv = self.engine.create_conversation(
                        messages=preface or None,
                        tools=[ProxyTool(t) for t in tools] or None,
                        automatic_tool_calling=False,
                        thinking_config=interfaces.ThinkingConfig(enable_thinking=thinking, thinking_token_budget=self.THINK_BUDGET if thinking else 0),
                        filter_channel_content_from_kv_cache=True,
                        max_output_tokens=(max_output_tokens or 2048) + (self.THINK_BUDGET if thinking else 0),
                    )
                    s = Session(id=session_id, conv=conv, key=key, fps=list(head_fps))
                    self._sessions[session_id] = s
                    self.counters["rebuilt"] += 1
                else:
                    self.counters["reused"] += 1
                self._evict(keep=session_id)
                s.last_used = time.time()
                s.turns += 1
                self.generating = True
                before = self._kv_tokens(s.conv)
                text_parts: list[str] = []
                calls: list[dict] = []
                # reasoning tokens count against the output limit, so thinking gets its own budget on top
                limit = (max_output_tokens + self.THINK_BUDGET) if (max_output_tokens and thinking) else max_output_tokens
                for chunk in s.conv.send_message_async(_collapse_tail(_to_litert(tail, names)), max_output_tokens=limit):
                    if cancel.is_set():
                        try:
                            s.conv.cancel_process()
                        except Exception:
                            pass
                        self._close(session_id)      # partial reply: the history no longer matches
                        print(f"meshnode  generation cancelled for session {session_id} (client stopped reading)", flush=True)
                        return
                    for tc in (getattr(chunk, "tool_calls", None) or []):
                        calls.append({"id": f"call_{uuid.uuid4().hex[:16]}", "type": "function",
                                      "function": {"name": tc.name, "arguments": json.dumps(dict(tc.arguments), ensure_ascii=False)}})
                    text = getattr(chunk, "text", None)
                    if text is None:
                        text = str(getattr(chunk, "contents", "") or "")
                    if text and not getattr(chunk, "channels", None):
                        text_parts.append(text)
                        q.put(("ev", {"type": "text", "text": text}))
                if calls:
                    q.put(("ev", {"type": "tool_calls", "calls": calls}))
                reply: Message = {"role": "assistant", "content": "".join(text_parts)}
                if calls:
                    reply["tool_calls"] = calls
                s.fps = head_fps + [_fp(m) for m in tail] + [_fp(reply)]
                q.put(("ev", {"type": "done", "finish": "tool_calls" if calls else "stop", "reused": reused,
                              "usage": self._usage(s.conv, before, reply["content"], calls)}))
            except Exception as ex:
                import traceback
                self._close(session_id); self.counters["errors"] += 1
                msg = str(ex)
                first = msg.splitlines()[0][:300] if msg else type(ex).__name__
                print(f"meshnode  error in session {session_id}: {type(ex).__name__}: {msg[:2000]}\n{traceback.format_exc()[-1500:]}", flush=True)
                if "parse tool call" in msg:
                    # The model wrote a slightly malformed call. Not an engine fault: no reset; send the raw block back
                    # so the client can recover the call (meshcore.toolparse).
                    q.put(("err", EngineError(f"engine error: {msg[:4000]}", 500)))
                elif "too long" in msg or ("token" in msg and ">=" in msg):
                    q.put(("err", EngineError(f"input exceeds this node's window of {self.max_num_tokens} tokens: {first}", 400)))
                else:
                    q.put(("err", EngineError(f"engine error: {first}", 500)))
                    try:
                        self._reset_engine(first)
                    except Exception as rex:
                        print(f"meshnode  engine reset failed: {rex}", flush=True)
            finally:
                self.generating = False
                if ephemeral:
                    self._close(session_id)
                elif session_id in self._sessions:
                    self._sessions[session_id].last_used = time.time()
                self._lock.release()
                q.put(("end", None))

        threading.Thread(target=work, name=f"gen-{session_id}", daemon=True).start()
        try:
            while True:
                kind, val = q.get()
                if kind == "ev":
                    yield val
                elif kind == "err":
                    raise val
                else:
                    return
        finally:
            cancel.set()      # client stopped reading: the worker cancels and releases the engine

    def chat(self, messages: list[Message], session_id: str, max_output_tokens: int | None = None) -> Iterator[str]:
        """Text-only convenience wrapper."""
        for ev in self.chat_events(messages, session_id, max_output_tokens=max_output_tokens):
            if ev["type"] == "text":
                yield ev["text"]

    def close(self) -> None:
        for sid in list(self._sessions):
            self._close(sid)
        try:
            self.engine.close()
        except Exception:
            pass
