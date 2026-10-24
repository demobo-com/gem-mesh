"""Anthropic Messages-API shim: the Claude Code harness on the mesh's local models.

Claude Code → (Anthropic Messages API) → shim → router → node (OpenAI chat with tools) → LiteRT-LM.

Translation
  system (str | blocks)                                         → system message
  mid-conversation role-"system" messages                       → <system-reminder> user notes, in place
  user text blocks                                              → user message
  user tool_result blocks                                       → tool messages (tool_call_id = tool_use_id)
  assistant text + tool_use blocks                              → assistant message with tool_calls (same ids)
  tools [{name, description, input_schema}]                     → OpenAI function tools
  model tool calls                                              → tool_use blocks, stop_reason "tool_use"

Sessions
  The agent loop (requests with tools) gets one live session per Claude Code session (metadata.user_id),
  pinned to the node it first routed to while that node stays reachable; the node then only prefills the
  new tail each step. Side requests without tools (titles, summaries) run in short-lived sessions so they
  never evict the agent's session.

Run:  gem-mesh shim            (port 8790)
Use:  ANTHROPIC_BASE_URL=http://127.0.0.1:8790 ANTHROPIC_API_KEY=mesh ANTHROPIC_MODEL=gemma4-26b claude
"""
from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import pathlib
import re
import time
import uuid

import uvicorn
from fastapi import Body, FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse, StreamingResponse

from meshcore.engine import text_of
from meshcore.nodes import NodeError
from meshcore.router import classify_rules

from . import web

from .session import ClientSession

app = FastAPI(title="gem-mesh shim")
STATE: dict = {"pins": {}}
from meshcore.profile import MESH_HOME
STATE_FILE = MESH_HOME / "shim-state.json"


def _save_state() -> None:
    try:
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        STATE_FILE.write_text(json.dumps({"force": STATE.get("force")}))
    except OSError:
        pass


def _load_state() -> None:
    try:
        STATE["force"] = json.loads(STATE_FILE.read_text()).get("force")
    except (OSError, ValueError):
        STATE["force"] = None
MAX_OUT = int(os.environ.get("MESH_SHIM_MAX_OUT", "4096"))


def _block_text(b) -> str:
    if isinstance(b, str):
        return b
    if not isinstance(b, dict):
        return ""
    t = b.get("type")
    if t == "text":
        return b.get("text", "")
    if t == "image":
        return "[image omitted: this model cannot see images]"
    if t == "document":
        return "[document omitted]"
    return ""


def _result_text(content) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(_block_text(b) for b in content)
    return str(content)


def anthropic_to_openai(body: dict) -> tuple[list[dict], list[dict]]:
    """Return (openai_messages, openai_tools)."""
    system = body.get("system") or ""
    if isinstance(system, list):
        system = "\n\n".join(_block_text(b) for b in system)
    extra_system: list[str] = []
    out: list[dict] = []
    for m in body.get("messages") or []:
        role, content = m.get("role"), m.get("content")
        if role not in ("user", "assistant"):
            # Claude Code inserts role "system" messages mid-conversation (environment, cwd changes). Keep them
            # where they occur as reminder notes: folding them into the system prompt would change it every
            # time and force the node to rebuild the whole conversation.
            note = _result_text(content).strip()
            if note:
                out.append({"role": "user", "content": f"<system-reminder>\n{note}\n</system-reminder>"})
            continue
        blocks = [{"type": "text", "text": content}] if isinstance(content, str) else (content or [])
        if role == "user":
            texts = []
            for b in blocks:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    txt = _result_text(b.get("content"))
                    if b.get("is_error"):
                        txt = f"[tool error]\n{txt}"
                    out.append({"role": "tool", "tool_call_id": b.get("tool_use_id"), "content": txt or "(no output)"})
                else:
                    t = _block_text(b)
                    if t:
                        texts.append(t)
            if texts:
                out.append({"role": "user", "content": "\n\n".join(texts)})
        else:
            texts, calls = [], []
            for b in blocks:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text":
                    texts.append(b.get("text", ""))
                elif b.get("type") == "tool_use":
                    calls.append({"id": b.get("id"), "type": "function",
                                  "function": {"name": b.get("name"), "arguments": json.dumps(b.get("input") or {}, ensure_ascii=False)}})
            msg = {"role": "assistant", "content": "".join(texts)}
            if calls:
                msg["tool_calls"] = calls
            out.append(msg)
    if extra_system:
        system = "\n\n".join([system] + extra_system).strip()
    if system:
        out.insert(0, {"role": "system", "content": system})
    tools = []
    for t in body.get("tools") or []:
        if "input_schema" not in t:     # server-side tools (web search etc.) cannot run locally
            continue
        tools.append({"type": "function", "function": {"name": t["name"], "description": t.get("description", ""),
                                                       "parameters": t.get("input_schema") or {"type": "object", "properties": {}}}})
    return out, tools



# Claude Code's own tools that a local model should see. Connector (MCP) tools add hundreds of schemas and
# overflow a 32K window; opt them in with MESH_SHIM_TOOLS="mcp__slack__*,SomeTool".
CORE_TOOLS = {"Bash", "BashOutput", "KillShell", "Read", "Edit", "MultiEdit", "Write", "Glob", "Grep", "LS",
              "NotebookEdit", "NotebookRead", "TodoWrite", "Task", "Agent", "ExitPlanMode", "WebFetch"}
_REMINDER = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)


def user_text(msgs: list[dict]) -> str:
    """What the user actually typed: user messages with Claude Code's injected reminders removed."""
    return "\n".join(_REMINDER.sub("", text_of(m.get("content"))) for m in msgs if m["role"] == "user").strip()


def select_tools(tools: list[dict], web_ok: bool) -> tuple[list[dict], list[str]]:
    extra = [x.strip() for x in os.environ.get("MESH_SHIM_TOOLS", "").split(",") if x.strip()]
    keep, dropped = [], []
    for t in tools:
        name = t["function"]["name"]
        allowed = name in CORE_TOOLS or any(fnmatch.fnmatch(name, pat) for pat in extra)
        if name == "WebFetch" and not web_ok:
            allowed = False
        (keep if allowed else dropped).append(t if allowed else name)
    if web_ok and tools:
        keep.append(web.TOOL)
    return keep, dropped



TIER_ALIASES = {"t0": "T0", "phone": "T0", "t1": "T1", "laptop": "T1", "macbook": "T1",
                "t2": "T2", "workstation": "T2", "ws": "T2", "t3": "T3", "server": "T3"}


def forced_target(model_name: str, nodes) -> tuple[str | None, str | None]:
    """Claude Code's /model picks the machine: `mesh-t2`, `mesh-workstation`, or a device name such as `my-workstation`.
    Anything else (gemma4-26b, mesh, auto) leaves routing automatic. Returns (tier, device)."""
    name = (model_name or "").strip().lower()
    for n in nodes:
        if name == n.device.lower():
            return None, n.device
    if name.startswith("mesh-"):
        return TIER_ALIASES.get(name[5:]), None
    return None, None

def run_events(client, msgs: list[dict], sid: str, tools: list[dict], max_tokens: int, ephemeral: bool,
               policy, web_used: list[str]):
    """Drive the node, executing shim-side tools (web_search) in place and returning only client tool calls."""
    convo = list(msgs)
    for _ in range(4):
        texts, calls, finish = [], [], "stop"
        for ev in client.chat_events(convo, sid, tools=tools or None, max_tokens=max_tokens, ephemeral=ephemeral):
            if ev["type"] == "text":
                texts.append(ev["text"]); yield ev
            elif ev["type"] == "tool_calls":
                calls = ev["calls"]
            elif ev["type"] == "done":
                finish = ev["finish"]
        if not any(c["function"]["name"] == "web_search" for c in calls):
            if calls:
                yield {"type": "tool_calls", "calls": calls}
            yield {"type": "done", "finish": finish}
            return
        convo.append({"role": "assistant", "content": "".join(texts), "tool_calls": calls})
        for c in calls:
            if c["function"]["name"] != "web_search":
                result = "Not executed: call this tool again on its own, after the search."
            else:
                try:
                    q = (json.loads(c["function"]["arguments"] or "{}").get("query") or "").strip()
                except json.JSONDecodeError:
                    q = ""
                priv, hits = classify_rules(q, policy)
                if len(web_used) >= 2:
                    result = ("Search limit reached for this turn. Do not search again. Call WebFetch on the most relevant "
                              "link from the earlier results, or answer from the snippets you already have.")
                elif not q:
                    result = "Error: empty query."
                elif priv != "public":
                    result = ("Blocked: the query contained private information (a client, person, email, figure or path) and was not sent. "
                              "Search again using only general, public terms.")
                    _log(f"web    blocked query ({'; '.join(hits)[:120]})")
                else:
                    try:
                        result = web.search(q) + ("\n\nAnswer the user from the page text above and name the source. "
                                                  "Only if it is missing, call WebFetch on the most relevant link. Do not search again for the same thing.")
                        web_used.append(q)
                        _log(f"web    search \"{q[:80]}\" → left the mesh")
                    except Exception as e:
                        result = f"Search failed: {e}"
            convo.append({"role": "tool", "tool_call_id": c["id"], "content": result})
        if texts:
            yield {"type": "text", "text": "\n\n"}
    yield {"type": "text", "text": "I searched the web but could not find a direct answer in the results."}
    yield {"type": "done", "finish": "stop"}


def _sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


def _session_key(body: dict) -> str:
    uid = ((body.get("metadata") or {}).get("user_id") or "")
    return hashlib.sha1(uid.encode()).hexdigest()[:12] if uid else "default"


def _log(line: str) -> None:
    print(line, flush=True)


@app.get("/health")
def health():
    s: ClientSession = STATE["session"]
    return {"status": "ok", "nodes": [n.label() for n in s.nodes()], "pins": STATE["pins"]}



def _tier_table(s: ClientSession) -> str:
    reach = {(n.base_url or "local") for n in s.nodes()}
    force = STATE.get("force") or "auto"
    rows = ["Mesh tiers (gem-mesh)", ""]
    rows.append("  T0  phone          gemma4-e4b   on the phone itself (not used by Claude Code)")
    for n in sorted(s.table.all_nodes(), key=lambda n: (s.policy.rank(n.tier), n.device)):
        if n.local:
            continue
        up = (n.base_url or "local") in reach
        mark = "●" if up else "○"
        state = f"reachable  {n.latency_ms:.0f} ms  load {n.load:.2f}" if up and n.latency_ms is not None else "unreachable"
        chosen = "   ← current" if force in (n.tier, n.device) else ""
        rows.append(f"  {n.tier:<3} {n.device:<14} {n.model:<12} {mark} {state}{chosen}")
    rows.append(f"  T4  frontier       Gemini       {'web search allowed for public questions' if s.policy.web == 'public' else 'web off by policy'}; frontier model not wired yet")
    rows += ["", f"Current: {force}" + ("   (automatic: lowest tier that fits each request)" if force == "auto" else ""),
             "Set with: /tier T1 | /tier T2 | /tier auto | /tier <device>"]
    return "\n".join(rows)



_TIER_CMD = re.compile(r'MESH_TIER_COMMAND args="(.*?)"', re.S)


def _set_tier(s: ClientSession, want: str) -> str:
    want = (want or "").strip()
    if not want:
        return ""
    devices = {n.device.lower(): n.device for n in s.table.all_nodes()}
    if want.lower() in ("auto", "mesh", "default"):
        STATE["force"] = None; note = "Tier set to automatic."
    elif want.upper() in ("T0", "T1", "T2", "T3"):
        STATE["force"] = want.upper(); note = f"Tier set to {want.upper()}. This conversation moves there on its next step."
    elif want.lower() in devices:
        STATE["force"] = devices[want.lower()]; note = f"Tier set to {devices[want.lower()]}. This conversation moves there on its next step."
    else:
        return f"Unknown tier or device: {want}\n\n"
    _log(f"tier   /tier {want} → {STATE.get('force') or 'auto'}")
    _save_state()
    return note + "\n\n"


def _text_reply(body: dict, text: str):
    """Answer without a model (shim commands)."""
    mid = f"msg_{uuid.uuid4().hex[:24]}"
    model_name = body.get("model") or "mesh"
    if not body.get("stream"):
        return {"id": mid, "type": "message", "role": "assistant", "model": model_name, "content": [{"type": "text", "text": text}],
                "stop_reason": "end_turn", "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}}
    def events():
        yield _sse("message_start", {"type": "message_start", "message": {"id": mid, "type": "message", "role": "assistant", "model": model_name,
                                                                          "content": [], "stop_reason": None, "stop_sequence": None,
                                                                          "usage": {"input_tokens": 1, "output_tokens": 1}}})
        yield _sse("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
        yield _sse("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}})
        yield _sse("content_block_stop", {"type": "content_block_stop", "index": 0})
        yield _sse("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 1}})
        yield _sse("message_stop", {"type": "message_stop"})
    return StreamingResponse(events(), media_type="text/event-stream", headers={"Cache-Control": "no-cache"})

@app.get("/mesh/tier", response_class=PlainTextResponse)
def mesh_tier(set: str | None = None):
    s: ClientSession = STATE["session"]
    s.table.refresh()
    return _set_tier(s, set or "") + _tier_table(s)


@app.post("/v1/messages/count_tokens")
async def count_tokens(request: Request):
    body = await request.json()
    return {"input_tokens": max(1, len(json.dumps(body, ensure_ascii=False)) // 4)}


@app.post("/v1/messages")
def messages(body: dict = Body(...)):
    s: ClientSession = STATE["session"]
    if os.environ.get("MESH_SHIM_DUMP"):   # a file keeps the last request; a directory keeps them all
        dp = pathlib.Path(os.environ["MESH_SHIM_DUMP"])
        STATE["n"] = STATE.get("n", 0) + 1
        target = dp / f"req-{STATE['n']:03d}.json" if dp.is_dir() else dp
        target.write_text(json.dumps(body, indent=1, ensure_ascii=False)[:2_000_000])
    msgs, tools = anthropic_to_openai(body)
    # /tier: look at everything the user sent since the model last replied (Claude Code may append notes after it)
    last_asst = max((i for i, m in enumerate(msgs) if m["role"] == "assistant"), default=-1)
    turn_text = "\n".join(text_of(m.get("content")) for m in msgs[last_asst + 1:] if m["role"] == "user")
    cmd = _TIER_CMD.search(turn_text) if not any(m["role"] == "tool" for m in msgs[last_asst + 1:]) else None
    if cmd:                                   # /tier: answered by the shim itself, no model call
        s.table.refresh()
        return _text_reply(body, "```\n" + _set_tier(s, cmd.group(1)) + _tier_table(s) + "\n```")
    agent = bool(tools)
    typed = user_text(msgs)
    user_priv, _ = classify_rules(typed, s.policy)
    # Web is allowed in any conversation: only a query or URL leaves, and each query is checked in run_events.
    # Strictness is for inference (frontier tier), not for search.
    web_ok = s.policy.web != "never" and s.network().mode != "offline"
    tools, dropped = select_tools(tools, web_ok)
    if dropped:
        _log(f"tools  {len(tools)} passed, {len(dropped)} connector tools dropped (opt in with MESH_SHIM_TOOLS)")
    if agent:
        _log(f"web    {'allowed (queries checked before they leave)' if web_ok else 'off: policy or offline'}")
        if not web_ok and msgs and msgs[0]["role"] == "system":
            why = "web access is disabled by policy or there is no network"
            msgs[0] = dict(msgs[0], content=msgs[0]["content"] + f"\n\n# Local mesh\nYou have no web search or web fetch tools here: {why}. "
                           "If the user needs live information, say so briefly and suggest they ask again without the private details.")
    model_name = body.get("model") or "mesh"
    max_tokens = min(int(body.get("max_tokens") or 1024), MAX_OUT)
    mid = f"msg_{uuid.uuid4().hex[:24]}"
    est_tokens = len(json.dumps([msgs, tools], ensure_ascii=False)) // 4

    # Route. The privacy scan sees all user/assistant/tool text; size includes system and tool schemas.
    history = [m for m in msgs if m["role"] != "system"]
    last_user = next((text_of(m.get("content")) for m in reversed(history) if m["role"] in ("user", "tool")), "")
    scan = "\n".join(text_of(m.get("content")) for m in history)
    decision = s.decide(last_user, context_tokens=max(0, est_tokens - len(last_user) // 4), scan_text=scan,
                        need_tokens=est_tokens + max_tokens)
    key = _session_key(body)
    pin = STATE["pins"].get(key) if agent else None
    node = None
    want_tier, want_device = forced_target(model_name, s.nodes())
    if not (want_tier or want_device) and STATE.get("force"):
        f = STATE["force"]
        want_tier, want_device = (f, None) if f in ("T0", "T1", "T2", "T3") else (None, f)
        model_name = f"/tier {f}"
    if want_tier or want_device:
        pick = [n for n in s.nodes() if (want_device and n.device == want_device) or (want_tier and n.tier == want_tier)]
        if pick:
            node = pick[0]
            if agent and STATE["pins"].get(key) != (node.base_url or "local"):
                _log(f"route  {model_name if model_name.startswith('/tier') else '/model ' + model_name} → moving session {key} to {node.device} / {node.model} (rebuilds context once)")
            elif not agent or not STATE["pins"].get(key):
                _log(f"route  {model_name if model_name.startswith('/tier') else '/model ' + model_name} → {node.device} / {node.model}")
            if agent:
                STATE["pins"][key] = node.base_url or "local"
            pin = None
        else:
            _log(f"route  {model_name if model_name.startswith('/tier') else '/model ' + model_name}: no reachable node matches, routing automatically")
    if pin:
        node = next((n for n in s.nodes() if (n.base_url or "local") == pin), None)
        if node:
            _log(f"route  session {key} pinned → {node.device} / {node.model}")
    if node is None and decision.chosen is None and not (want_tier or want_device):
        pass
    if node is None:
        for line in decision.log:
            _log(line)
        node = decision.chosen
        if node is None:
            return JSONResponse({"type": "error", "error": {"type": "overloaded_error",
                                 "message": f"mesh: no reachable node fits this request (needs {decision.needs}, ~{est_tokens} tokens)"}}, status_code=529)
        if agent:
            STATE["pins"][key] = node.base_url or "local"
    client = s.table.client_for(node)
    sid = f"cc-{key}-{'agent' if agent else 'side'}"
    web_used: list[str] = []
    gen = run_events(client, msgs, sid, tools, max_tokens, not agent, s.policy, web_used)
    t0 = time.time()

    def badge(stop: str, ncalls: int) -> None:
        _log(f"badge  {node.device} · {node.model} · {'agent' if agent else 'side'} · {stop}"
             + (f" · {ncalls} tool call(s)" if ncalls else "")
             + (f" · web: {len(web_used)} search(es) left the mesh" if web_used else " · 0 bytes left the mesh") + f" · {time.time()-t0:.1f} s")

    def err_response(e: NodeError):
        if e.status >= 500:
            STATE["pins"].pop(key, None)   # let the next step re-route
        msg = str(e)
        if "window" in msg:
            msg = f"prompt is too long: {msg}"
        _log(f"error  {node.device}: {e.status} {msg[:160]}")
        return JSONResponse({"type": "error", "error": {"type": "invalid_request_error" if e.status == 400 else "api_error", "message": msg}},
                            status_code=e.status)

    if not body.get("stream"):
        texts, calls = [], []
        try:
            for ev in gen:
                if ev["type"] == "text": texts.append(ev["text"])
                elif ev["type"] == "tool_calls": calls = ev["calls"]
        except NodeError as e:
            return err_response(e)
        text = "".join(texts)
        content = ([{"type": "text", "text": text}] if text.strip() else []) + [
            {"type": "tool_use", "id": c["id"], "name": c["function"]["name"], "input": json.loads(c["function"]["arguments"] or "{}")} for c in calls]
        stop = "tool_use" if calls else "end_turn"
        badge(stop, len(calls))
        return {"id": mid, "type": "message", "role": "assistant", "model": model_name, "content": content or [{"type": "text", "text": ""}],
                "stop_reason": stop, "stop_sequence": None, "usage": {"input_tokens": est_tokens, "output_tokens": 0}}

    try:
        first = next(gen)
    except NodeError as e:
        return err_response(e)
    except StopIteration:
        first = {"type": "done", "finish": "stop"}

    def events():
        yield _sse("message_start", {"type": "message_start", "message": {"id": mid, "type": "message", "role": "assistant", "model": model_name,
                                                                          "content": [], "stop_reason": None, "stop_sequence": None,
                                                                          "usage": {"input_tokens": est_tokens, "output_tokens": 1}}})
        idx, text_open, ntext, calls = 0, False, 0, []
        ev = first
        try:
            while True:
                if ev["type"] == "text":
                    if not text_open:
                        yield _sse("content_block_start", {"type": "content_block_start", "index": idx, "content_block": {"type": "text", "text": ""}})
                        text_open = True
                    ntext += 1
                    yield _sse("content_block_delta", {"type": "content_block_delta", "index": idx, "delta": {"type": "text_delta", "text": ev["text"]}})
                elif ev["type"] == "tool_calls":
                    calls = ev["calls"]
                elif ev["type"] == "done":
                    break
                ev = next(gen)
        except StopIteration:
            pass
        except NodeError as e:
            _log(f"error  {node.device}: {e.status} {str(e)[:160]}")
            if not text_open:
                yield _sse("content_block_start", {"type": "content_block_start", "index": idx, "content_block": {"type": "text", "text": ""}})
                text_open = True
            yield _sse("content_block_delta", {"type": "content_block_delta", "index": idx, "delta": {"type": "text_delta", "text": f"\n[mesh error: {e}]"}})
        if text_open:
            yield _sse("content_block_stop", {"type": "content_block_stop", "index": idx})
            idx += 1
        for c in calls:
            yield _sse("content_block_start", {"type": "content_block_start", "index": idx,
                                               "content_block": {"type": "tool_use", "id": c["id"], "name": c["function"]["name"], "input": {}}})
            yield _sse("content_block_delta", {"type": "content_block_delta", "index": idx,
                                               "delta": {"type": "input_json_delta", "partial_json": c["function"]["arguments"] or "{}"}})
            yield _sse("content_block_stop", {"type": "content_block_stop", "index": idx})
            idx += 1
        if idx == 0:  # never send an empty message
            yield _sse("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
            yield _sse("content_block_stop", {"type": "content_block_stop", "index": 0})
        stop = "tool_use" if calls else "end_turn"
        yield _sse("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": max(1, ntext)}})
        yield _sse("message_stop", {"type": "message_stop"})
        badge(stop, len(calls))

    return StreamingResponse(events(), media_type="text/event-stream", headers={"Cache-Control": "no-cache"})


def serve(role: str | None, network: str | None, host: str = "127.0.0.1", port: int = 8790) -> int:
    s = ClientSession.start(role=role, network=network, with_local=False)
    s.table.wait(1.5)
    STATE["session"] = s
    _load_state()
    if STATE.get("force"):
        print(f"shim   tier preference restored: {STATE['force']}", flush=True)
    print(f"shim   listening on http://{host}:{port}  (ANTHROPIC_BASE_URL)  mesh: {s.mesh_line()}", flush=True)
    uvicorn.run(app, host=host, port=port, log_level="warning")
    s.close()
    return 0
