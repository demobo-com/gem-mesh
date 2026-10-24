"""OpenAI-compatible node server over LiteRT-LM.

Endpoints: GET /health, GET /mesh/info, GET /v1/models, POST /v1/chat/completions (stream or not).
One live conversation per session id (X-Session-Id header, `session_id` or `user` in the body),
idle eviction, a cap on resident sessions, and an mDNS record with tier, model and load.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid
from typing import Any

import uvicorn
from fastapi import Body, FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

from meshcore.discovery import Advertiser
from meshcore.engine import EngineError, LocalEngine
from meshcore.profile import load_profile

app = FastAPI(title="meshnode")
STATE: dict[str, Any] = {}


# ---- pairing: when the mesh is paired, every request but /health and /mesh/ca needs the mesh key -------------
@app.middleware("http")
async def mesh_auth(request: Request, call_next):
    mesh = STATE.get("mesh")
    if mesh is not None:
        from meshcore.security import OPEN_PATHS
        if request.url.path not in OPEN_PATHS and not mesh.check_bearer(request.headers.get("authorization")):
            return JSONResponse({"error": {"message": "this mesh is paired: send the mesh key (Authorization: Bearer ...)",
                                           "type": "authentication_error", "code": "pairing_required"}}, status_code=401)
    return await call_next(request)


@app.get("/mesh/ca")
def mesh_ca():
    """The mesh authority's certificate (public). A joining device checks it against the pairing code's fingerprint."""
    mesh = STATE.get("mesh")
    if mesh is None:
        return JSONResponse({"error": {"message": "this mesh is open (not paired)"}}, status_code=404)
    return {"ca_pem": mesh.ca_pem.read_text(), "fingerprint": mesh.ca_fingerprint()}


@app.post("/mesh/enroll")
def mesh_enroll(body: dict = Body(...)):
    """A device with the mesh key gets its own certificate (for its memory server or node). Only where the authority lives."""
    mesh = STATE.get("mesh")
    if mesh is None or not mesh.can_enroll:
        return JSONResponse({"error": {"message": "enroll on the device that created the mesh (gem-mesh pair)"}}, status_code=404)
    device = str(body.get("device") or "device")[:63]
    cert, key = mesh.issue(device, sans=[str(x) for x in (body.get("names") or [])][:8])
    print(f"meshnode  enrolled {device} ({body.get('role', 'device')})", flush=True)
    return {"cert_pem": cert, "key_pem": key, "ca_pem": mesh.ca_pem.read_text(), "fingerprint": mesh.ca_fingerprint()}


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/mesh/info")
def mesh_info():
    eng: LocalEngine = STATE["engine"]; prof = STATE["profile"]
    st = eng.stats()
    return {"device": prof.device, "tier": prof.tier, "model": eng.model_id, "mesh": prof.mesh, "role": prof.role,
            "sessions": st["sessions"], "max_sessions": st["max_sessions"], "generating": st["generating"],
            "max_num_tokens": st["max_num_tokens"], "requests": st["requests"], "reused": st["reused"], "rebuilt": st["rebuilt"], "errors": st["errors"], "resets": st["resets"],
            "tokens_in": st["tokens_in"], "tokens_out": st["tokens_out"], "tokens_cached": st["tokens_cached"],
            "load": st["load"], "init_seconds": st["init_seconds"], "uptime_seconds": round(time.time() - STATE["started"], 1)}


@app.get("/v1/models")
def models():
    eng: LocalEngine = STATE["engine"]
    return {"object": "list", "data": [{"id": eng.model_id, "object": "model", "created": int(STATE["started"]), "owned_by": "gem-mesh"}]}


ZERO_USAGE = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}


def _sse(obj: dict) -> str:
    return f"data: {json.dumps(obj)}\n\n"


@app.post("/v1/chat/completions")
def chat_completions(request: Request, body: dict = Body(...)):
    """OpenAI chat completions with tools. Extra mesh fields: session_id (or X-Session-Id), ephemeral, thinking.
    A plain (sync) handler: FastAPI runs it in the thread pool, so a busy model never stalls /health."""
    eng: LocalEngine = STATE["engine"]; prof = STATE["profile"]
    messages = body.get("messages") or []
    tools = [t for t in (body.get("tools") or []) if t.get("type") == "function"]
    session_id = request.headers.get("x-session-id") or body.get("session_id") or body.get("user") or f"anon-{uuid.uuid4().hex[:8]}"
    ephemeral = bool(body.get("ephemeral")) or session_id.startswith("anon-")
    max_tokens = body.get("max_tokens") or body.get("max_completion_tokens")
    thinking = bool(body.get("thinking"))
    stream = bool(body.get("stream"))
    include_usage = bool((body.get("stream_options") or {}).get("include_usage"))
    cid = f"chatcmpl_{uuid.uuid4().hex[:24]}"
    created = int(time.time())
    mesh = {"device": prof.device, "tier": prof.tier, "session_id": session_id}

    def err(e: EngineError):
        return JSONResponse({"error": {"message": str(e), "type": "invalid_request_error" if e.status == 400 else "server_error",
                                       "code": "context_length_exceeded" if "window" in str(e) else None}}, status_code=e.status)

    gen = eng.chat_events(messages, session_id, tools=tools, max_output_tokens=max_tokens, thinking=thinking, ephemeral=ephemeral)
    if not stream:
        text, calls, finish, usage = [], [], "stop", {}
        try:
            for ev in gen:
                if ev["type"] == "text": text.append(ev["text"])
                elif ev["type"] == "tool_calls": calls = ev["calls"]
                elif ev["type"] == "done": finish = ev["finish"]; mesh["reused"] = ev["reused"]; usage = ev.get("usage") or {}
        except EngineError as e:
            return err(e)
        msg = {"role": "assistant", "content": "".join(text) or None}
        if calls: msg["tool_calls"] = calls
        return {"id": cid, "object": "chat.completion", "created": created, "model": eng.model_id,
                "choices": [{"index": 0, "message": msg, "finish_reason": finish}],
                "usage": usage or ZERO_USAGE, "mesh": mesh}

    # Streaming: pull the first event before answering so bad requests still get a proper status code.
    try:
        first = next(gen)
    except EngineError as e:
        return err(e)
    except StopIteration:
        first = {"type": "done", "finish": "stop", "reused": False}

    def chunk(delta: dict, finish=None, usage=None) -> str:
        obj = {"id": cid, "object": "chat.completion.chunk", "created": created, "model": eng.model_id,
               "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        if usage:
            obj["usage"] = usage
        return _sse(obj)

    def events():
        yield chunk({"role": "assistant"})
        ev = first
        try:
            while True:
                if ev["type"] == "text":
                    yield chunk({"content": ev["text"]})
                elif ev["type"] == "tool_calls":
                    yield chunk({"tool_calls": [dict(c, index=i) for i, c in enumerate(ev["calls"])]})
                elif ev["type"] == "done":
                    # Usage rides on the finishing chunk (mesh clients read it there); OpenAI's own usage-only
                    # chunk follows when the request asked for it with stream_options.include_usage.
                    usage = ev.get("usage") or ZERO_USAGE
                    yield chunk({}, ev["finish"], usage)
                    if include_usage:
                        yield _sse({"id": cid, "object": "chat.completion.chunk", "created": created, "model": eng.model_id,
                                    "choices": [], "usage": usage})
                    break
                ev = next(gen)
        except StopIteration:
            yield chunk({}, "stop")
        except EngineError as e:
            yield _sse({"error": {"message": str(e), "status": e.status}})
        yield "data: [DONE]\n\n"

    return StreamingResponse(events(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Session-Id": session_id,
                                      "X-Mesh-Device": prof.device, "X-Mesh-Tier": prof.tier})


def main(argv=None) -> int:
    from meshcore import quiet_native_logs
    quiet_native_logs()
    ap = argparse.ArgumentParser(prog="meshnode", description="Gem Mesh node server")
    ap.add_argument("--role", help="profile to load (default: macbook profile)")
    ap.add_argument("--model", help="override the model id from the profile")
    ap.add_argument("--port", type=int); ap.add_argument("--host")
    ap.add_argument("--max-sessions", type=int, help="override the profile (workstation/server default 1: two 13K sessions OOM the 31B on 32 GB)"); ap.add_argument("--idle-seconds", type=int, default=600)
    ap.add_argument("--no-advertise", action="store_true")
    a = ap.parse_args(argv)
    prof = load_profile(role=a.role, model=a.model, node_port=a.port, node_host=a.host)
    mp = prof.model_path()
    if not mp.exists():
        print(f"model file missing: {mp}\nrun: mesh models pull {prof.model}", file=sys.stderr); return 1
    print(f"meshnode  device={prof.device} role={prof.role} tier={prof.tier} model={prof.model} port={prof.node_port}", flush=True)
    t0 = time.time()
    eng = LocalEngine(prof.model, mp, max_num_tokens=prof.max_num_tokens, max_sessions=a.max_sessions or prof.max_sessions, idle_seconds=a.idle_seconds, cache=prof.cache)
    print(f"meshnode  engine ready in {time.time() - t0:.1f}s", flush=True)
    from meshcore import security
    mesh = security.load()
    STATE.update(engine=eng, profile=prof, started=time.time(), mesh=mesh)
    extra = {"tls": "1", "ca": mesh.ca_fingerprint()[:16]} if mesh else {}
    print(f"meshnode  {'paired: HTTPS, mesh key required' if mesh else 'open: plain HTTP, anyone on this network can use it (gem-mesh pair to secure it)'}", flush=True)
    adv = None
    if prof.advertise and not a.no_advertise:
        adv = Advertiser(prof.device, prof.tier, prof.model, prof.node_port, prof.mesh, load_fn=lambda: eng.stats()["load"], extra=extra)
        adv.start(); print(f"meshnode  advertising _local-ai._tcp as {prof.device}-{prof.tier.lower()}", flush=True)
    try:
        tls = {"ssl_certfile": str(mesh.cert_pem), "ssl_keyfile": str(mesh.cert_key)} if mesh else {}
        uvicorn.run(app, host=prof.node_host, port=prof.node_port, log_level=os.environ.get("MESHNODE_LOG", "warning"), **tls)
    finally:
        if adv: adv.stop()
        eng.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
