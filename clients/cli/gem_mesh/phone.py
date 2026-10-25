"""AGI's phone agent over MCP (streamable HTTP, JSON-RPC 2.0), the laptop side of the Android app's Use the phone.

A task in plain words runs on a phone that has the AGI app with its accessibility service on. Every step sends a
screenshot of that phone to AGI and costs a cent, so /phone asks first. Key: AGI_API_KEY; endpoint: MESH_AGI_URL.
"""
from __future__ import annotations

import json
import os
from typing import Callable

import httpx

URL = "https://api.agi.tech/v1/mcp"
VERSION = "2025-06-18"
MONITOR_S = 15      # short waits, so the step count moves and Ctrl-C is noticed between them


class PhoneAgentError(Exception):
    pass


class PhoneAgent:
    def __init__(self, key: str, url: str | None = None):
        self.url = url or os.environ.get("MESH_AGI_URL", URL)
        self.http = httpx.Client(timeout=90, headers={
            "Authorization": f"Bearer {key}", "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": VERSION})
        self.next_id = 0
        self.ready = False

    def _rpc(self, method: str, params: dict | None = None) -> dict | None:
        note = method.startswith("notifications/")
        body: dict = {"jsonrpc": "2.0", "method": method}
        if not note:
            self.next_id += 1
            body["id"] = self.next_id
        if params is not None:
            body["params"] = params
        r = self.http.post(self.url, json=body)
        if sid := r.headers.get("mcp-session-id"):
            self.http.headers["Mcp-Session-Id"] = sid
        if r.status_code == 401:
            raise PhoneAgentError("AGI refused the key (AGI_API_KEY)")
        if r.status_code >= 400:
            raise PhoneAgentError(f"AGI: HTTP {r.status_code} {r.text[:200]}")
        if note:
            return None
        text = r.text
        if r.headers.get("content-type", "").startswith("text/event-stream"):   # the reply rides on a data line
            lines = [ln[5:].strip() for ln in text.splitlines() if ln.startswith("data:") and '"id"' in ln]
            if not lines:
                raise PhoneAgentError("AGI: empty event stream")
            text = lines[-1]
        o = json.loads(text)
        if err := o.get("error"):
            raise PhoneAgentError(f"AGI: {err.get('message')}")
        return o["result"]

    def call(self, tool: str, args: dict | None = None) -> dict:
        """One tool call; the tool's text content parsed as JSON."""
        if not self.ready:
            self._rpc("initialize", {"protocolVersion": VERSION, "capabilities": {}, "clientInfo": {"name": "gem-mesh", "version": "0.1.0"}})
            self._rpc("notifications/initialized")
            self.ready = True
        res = self._rpc("tools/call", {"name": tool, "arguments": args or {}}) or {}
        text = "".join(c.get("text", "") for c in res.get("content", []))
        if res.get("isError"):
            raise PhoneAgentError(f"AGI: {text[:300]}")
        try:
            return json.loads(text)
        except ValueError:
            return {"text": text}

    def device(self) -> dict:
        """The default device if it is online, else the first online one."""
        online = [d for d in self.call("list_devices").get("devices", []) if d.get("status") == "online" and not d.get("paused")]
        if not online:
            raise PhoneAgentError("no phone is online in AGI: open the AGI app on the phone and sign in")
        return next((d for d in online if d.get("is_default")), online[0])

    def run(self, prompt: str, on_steps: Callable[[int], None] = lambda n: None) -> dict:
        """Runs one task until it pauses or finishes. Ctrl-C cancels it on the phone and returns how it ended."""
        dev = self.device()
        started = self.call("phone_run_task", {"device_id": dev["device_id"], "prompt": prompt})
        task, session = started["task_id"], started.get("session_id", "")
        try:
            while True:
                s = self.call("phone_task_monitor", {"task_id": task, "timeout_s": MONITOR_S})
                on_steps(s.get("step_count", 0))
                if s.get("status") in ("completed", "paused"):
                    break
        except KeyboardInterrupt:
            self.call("phone_task_cancel", {"session_id": session, "task_id": task, "reason": "stopped in gem-mesh"})
            s = self.call("phone_task_status", {"task_id": task})
        summary = (s.get("result") or {}).get("summary") or (s.get("error") or {}).get("message") or ""
        return {"device": dev.get("device_name") or dev.get("device_model", ""), "status": s.get("status"),
                "terminal": s.get("terminal", ""), "steps": s.get("step_count", 0), "summary": summary}
