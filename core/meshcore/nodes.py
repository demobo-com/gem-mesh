"""Nodes the router can send to: a remote meshnode over HTTP, or a local in-process engine."""
from __future__ import annotations

import json
import time
from collections.abc import Iterator
from dataclasses import dataclass, field
from typing import Any

import httpx

from .engine import EngineError, LocalEngine


class NodeError(Exception):
    def __init__(self, message: str, status: int = 500):
        super().__init__(message)
        self.status = status


@dataclass
class NodeInfo:
    name: str
    device: str
    tier: str
    model: str
    base_url: str | None = None          # None for the in-process node
    load: float = 0.0
    max_num_tokens: int | None = None
    latency_ms: float | None = None
    source: str = "mdns"                 # mdns | static | local
    seen: float = field(default_factory=time.time)
    props: dict[str, Any] = field(default_factory=dict)

    @property
    def local(self) -> bool:
        return self.base_url is None

    def label(self) -> str:
        return f"{self.device} {self.tier} {self.model}"


class RemoteNode:
    def __init__(self, info: NodeInfo, timeout: float = 600.0, secure: dict | None = None):
        """`secure`: httpx settings of a paired mesh (pinned authority, mesh key); None for an open mesh."""
        self.info = info
        self.client = httpx.Client(timeout=httpx.Timeout(timeout, connect=5.0), **(secure or {}))

    def health(self) -> dict | None:
        t0 = time.time()
        try:
            r = self.client.get(f"{self.info.base_url}/mesh/info", timeout=3.0)
            r.raise_for_status()
            self.info.latency_ms = round((time.time() - t0) * 1000, 1)
            d = r.json()
            self.info.load = float(d.get("load", 0.0))
            self.info.model = d.get("model", self.info.model)
            self.info.tier = d.get("tier", self.info.tier)
            self.info.device = d.get("device", self.info.device)
            self.info.max_num_tokens = d.get("max_num_tokens", self.info.max_num_tokens)
            self.info.seen = time.time()
            return d
        except Exception:
            self.info.latency_ms = None      # unreachable until the next successful check
            return None

    def chat_events(self, messages: list[dict], session_id: str, tools: list[dict] | None = None,
                    max_tokens: int | None = None, thinking: bool = False, ephemeral: bool = False) -> Iterator[dict]:
        """Same event protocol as LocalEngine.chat_events, over HTTP."""
        body = {"model": self.info.model, "messages": messages, "stream": True, "session_id": session_id,
                "ephemeral": ephemeral, "thinking": thinking}
        if tools:
            body["tools"] = tools
        if max_tokens:
            body["max_tokens"] = max_tokens
        try:
            yield from self._stream(body, session_id)
        except httpx.HTTPError as e:            # node went away mid-request: a clean, retryable error
            self.info.latency_ms = None
            raise NodeError(f"{self.info.device} unavailable: {type(e).__name__}", 503) from e

    def _stream(self, body: dict, session_id: str) -> Iterator[dict]:
        with self.client.stream("POST", f"{self.info.base_url}/v1/chat/completions", json=body,
                                headers={"X-Session-Id": session_id}) as r:
            if r.status_code >= 400:
                r.read()
                try:
                    msg = r.json().get("error", {}).get("message", r.text)
                except Exception:
                    msg = r.text
                raise NodeError(msg, r.status_code)
            finish, usage = "stop", {}
            for line in r.iter_lines():
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    obj = json.loads(data)
                except json.JSONDecodeError:
                    continue
                if "error" in obj:
                    raise NodeError(obj["error"].get("message", "node error"), obj["error"].get("status", 500))
                ch = (obj.get("choices") or [{}])[0]
                delta = ch.get("delta") or {}
                if delta.get("content"):
                    yield {"type": "text", "text": delta["content"]}
                if delta.get("tool_calls"):
                    yield {"type": "tool_calls", "calls": [{k: v for k, v in c.items() if k != "index"} for c in delta["tool_calls"]]}
                if ch.get("finish_reason"):
                    finish = ch["finish_reason"]
                if obj.get("usage"):
                    usage = obj["usage"]
            yield {"type": "done", "finish": finish, "reused": None, "usage": usage}

    def chat(self, messages: list[dict], session_id: str, max_tokens: int | None = None) -> Iterator[str]:
        for ev in self.chat_events(messages, session_id, max_tokens=max_tokens):
            if ev["type"] == "text":
                yield ev["text"]


class LocalNode:
    """The phone's own model, or the mock mobile's E4B: in-process, never advertised."""

    def __init__(self, info: NodeInfo, engine: LocalEngine):
        self.info = info
        self.engine = engine
        self.info.source = "local"

    def health(self) -> dict:
        st = self.engine.stats()
        self.info.load = st["load"]
        self.info.max_num_tokens = st["max_num_tokens"]
        self.info.latency_ms = 0.0
        return st

    def chat_events(self, messages: list[dict], session_id: str, tools: list[dict] | None = None,
                    max_tokens: int | None = None, thinking: bool = False, ephemeral: bool = False) -> Iterator[dict]:
        try:
            yield from self.engine.chat_events(messages, session_id, tools=tools, max_output_tokens=max_tokens,
                                               thinking=thinking, ephemeral=ephemeral)
        except EngineError as e:
            raise NodeError(str(e), e.status) from e

    def chat(self, messages: list[dict], session_id: str, max_tokens: int | None = None) -> Iterator[str]:
        yield from self.engine.chat(messages, session_id, max_output_tokens=max_tokens)
