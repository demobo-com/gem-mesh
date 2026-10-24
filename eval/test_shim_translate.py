"""Shim translation tests, no model needed. Run: .venv/bin/python eval/test_shim_translate.py"""
import json, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "core"), str(ROOT / "clients/cli")]
from gem_mesh.shim import anthropic_to_openai

body = {
  "system": [{"type": "text", "text": "You are Claude Code."}],
  "tools": [{"name": "Read", "description": "Read a file", "input_schema": {"type": "object", "properties": {"file_path": {"type": "string"}}, "required": ["file_path"]}},
            {"type": "web_search_20250305", "name": "web_search"}],
  "messages": [
    {"role": "user", "content": [{"type": "text", "text": "<system-reminder>x</system-reminder>"}, {"type": "text", "text": "What port is in app.yaml?"}]},
    {"role": "assistant", "content": [{"type": "text", "text": "Reading it."}, {"type": "tool_use", "id": "toolu_1", "name": "Read", "input": {"file_path": "app.yaml"}}]},
    {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_1", "content": [{"type": "text", "text": "port: 8443"}]}]},
    {"role": "system", "content": "# Environment\ncwd: /tmp/x"},
  ]}
msgs, tools = anthropic_to_openai(body)
checks = [
  ("system prompt stays the system prompt", msgs[0] == {"role": "system", "content": "You are Claude Code."}),
  ("mid-conversation role-system kept in place as a note", msgs[-1]["role"] == "user" and "Environment" in msgs[-1]["content"] and msgs[-2]["role"] == "tool"),
  ("user text joined", msgs[1] == {"role": "user", "content": "<system-reminder>x</system-reminder>\n\nWhat port is in app.yaml?"}),
  ("assistant tool_use → tool_calls with same id", msgs[2]["tool_calls"][0]["id"] == "toolu_1" and json.loads(msgs[2]["tool_calls"][0]["function"]["arguments"]) == {"file_path": "app.yaml"}),
  ("tool_result → tool message", msgs[3] == {"role": "tool", "tool_call_id": "toolu_1", "content": "port: 8443"}),
  ("tools mapped, server tool dropped", [t["function"]["name"] for t in tools] == ["Read"] and tools[0]["function"]["parameters"]["required"] == ["file_path"]),
]
fails = 0
for name, ok in checks:
    fails += not ok; print(("ok  " if ok else "XX  ") + name)
print(f"\n{len(checks)-fails}/{len(checks)} passed"); sys.exit(1 if fails else 0)
