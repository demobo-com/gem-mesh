"""Lenient recovery of Gemma tool calls that LiteRT-LM refused to parse.

Gemma writes calls as  call:name{key:<|"|>text<|"|>,n:3,xs:[1,2]}  and LiteRT-LM rejects the whole answer when one
separator is missing (seen: `<|"|>rotate<|"|>degrees:90`). The engine's error carries the raw block; this reads it
forgivingly so the chat can carry on instead of failing.
"""
from __future__ import annotations

import json
import re
import uuid

Q = '<|"|>'
_CALL = re.compile(r"call:([A-Za-z_][\w.-]*)\s*\{")


def _value(s: str, i: int):
    while i < len(s) and s[i] in " \n\t":
        i += 1
    if s.startswith(Q, i):
        j = s.find(Q, i + len(Q))
        j = len(s) if j < 0 else j
        return s[i + len(Q):j], j + len(Q)
    if i < len(s) and s[i] == "[":
        items, i = [], i + 1
        while i < len(s) and s[i] != "]":
            if s[i] in ", \n":
                i += 1; continue
            v, i = _value(s, i)
            items.append(v)
        return items, i + 1
    if i < len(s) and s[i] == "{":
        obj, i = _object(s, i + 1)
        return obj, i
    m = re.match(r"[^,}\]\s]+", s[i:])
    raw = m.group(0) if m else ""
    i += len(raw)
    for conv in (int, float):
        try:
            return conv(raw), i
        except ValueError:
            pass
    return {"true": True, "false": False, "null": None}.get(raw, raw), i


def _object(s: str, i: int):
    out = {}
    while i < len(s):
        while i < len(s) and s[i] in ", \n\t":
            i += 1
        if i >= len(s) or s[i] == "}":
            return out, i + 1
        m = re.match(r'"?([A-Za-z_][\w-]*)"?\s*:', s[i:])
        if not m:
            return out, len(s)
        i += m.end()
        out[m.group(1)], i = _value(s, i)
    return out, i


def recover_calls(error_text: str) -> list[dict]:
    """OpenAI-style tool_calls from an engine 'Failed to parse tool calls' message, or [] if nothing usable."""
    if "parse tool call" not in error_text:
        return []
    calls = []
    for m in _CALL.finditer(error_text):
        try:
            args, _ = _object(error_text, m.end())
        except Exception:
            continue
        calls.append({"id": f"call_{uuid.uuid4().hex[:12]}", "type": "function",
                      "function": {"name": m.group(1), "arguments": json.dumps(args)}})
    return calls
