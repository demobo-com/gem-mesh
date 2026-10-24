"""The authority's memory endpoint: the phone (or the mobile stand-in) serves its events to the paired laptop.

Runs inside the mobile client's process on a background thread while the client is open, the way the phone
app would serve its mirror over the hotspot or Wi-Fi.
"""
from __future__ import annotations

import threading

import uvicorn
from fastapi import Body, FastAPI

from .memory import MemoryStore


def make_app(store: MemoryStore, mesh=None) -> FastAPI:
    """`mesh`: the paired mesh (meshcore.security.Mesh) or None. Paired: the mesh key is required on every call."""
    app = FastAPI(title="mesh memory")

    if mesh is not None:
        from fastapi import Request
        from fastapi.responses import JSONResponse

        @app.middleware("http")
        async def auth(request: Request, call_next):
            if not mesh.check_bearer(request.headers.get("authorization")):
                return JSONResponse({"error": {"message": "this mesh is paired: send the mesh key", "code": "pairing_required"}},
                                    status_code=401)
            return await call_next(request)

    @app.get("/memory/status")
    def status():
        return store.stats()

    @app.get("/memory/pull")
    def pull(after: int = 0, limit: int = 500):
        events, last = store.events_after(after, limit)
        return {"events": events, "last": last}

    @app.post("/memory/push")
    def push(body: dict = Body(...)):
        return {"accepted": store.ingest(body.get("events") or [])}

    return app


def serve_in_background(store: MemoryStore, host: str, port: int, mesh=None) -> uvicorn.Server:
    tls = {"ssl_certfile": str(mesh.cert_pem), "ssl_keyfile": str(mesh.cert_key)} if mesh else {}
    server = uvicorn.Server(uvicorn.Config(make_app(store, mesh), host=host, port=port, log_level="warning", **tls))
    threading.Thread(target=server.run, name="memory-server", daemon=True).start()
    return server
