"""Do what the Android app does, with nothing but mDNS and HTTP: an executable spec for gem-mesh-android.

    uv run python scripts/phone-client-check.py            # find the Mac over mDNS
    uv run python scripts/phone-client-check.py http://192.168.1.20:9400   # or use the address from `gem-mesh pair`

Steps (each one prints what it sent and got, so the Kotlin port can compare byte for byte):
  1. browse _local-ai._tcp, keep records with api=openai and the right mesh (api=memory is a phone, not a model)
  2. GET /health and /mesh/info
  3. POST /v1/chat/completions with one tool; run the tool locally; send the result; print the final answer
It does not use meshcore, on purpose.
"""
import json
import sys
import time

import httpx
from zeroconf import ServiceBrowser, ServiceStateChange, Zeroconf

MESH = "default"
TYPE = "_local-ai._tcp.local."


def find_nodes(seconds: float = 3.0) -> list[dict]:
    found = []

    def on_change(zeroconf, service_type, name, state_change):
        if state_change is not ServiceStateChange.Added:
            return
        info = zeroconf.get_service_info(service_type, name, 2000)
        if not info:
            return
        p = {k.decode(): (v.decode() if v else "") for k, v in info.properties.items()}
        addrs = info.parsed_addresses()
        print(f"  mDNS  {name.split('.')[0]:<22} api={p.get('api')} tier={p.get('tier')} model={p.get('model')} mesh={p.get('mesh')} → {addrs[0] if addrs else '?'}:{info.port}")
        if p.get("api") == "openai" and p.get("mesh", "default") == MESH and addrs:
            found.append({"url": f"http://{addrs[0]}:{info.port}", **p})

    zc = Zeroconf()
    ServiceBrowser(zc, TYPE, handlers=[on_change])
    time.sleep(seconds)
    zc.close()
    return found


TOOLS = [{"type": "function", "function": {
    "name": "get_battery", "description": "Read the phone's battery level.",
    "parameters": {"type": "object", "properties": {}}}}]


def main() -> int:
    if len(sys.argv) > 1:
        nodes = [{"url": sys.argv[1].rstrip("/")}]
    else:
        print("1. discovery")
        nodes = sorted(find_nodes(), key=lambda n: n.get("tier", "T9"))
        if not nodes:
            print("  no model nodes found: same Wi-Fi? firewall? try the address from `gem-mesh pair`")
            return 1
    url = nodes[0]["url"]
    print(f"\n2. health  {url}")
    with httpx.Client(timeout=120) as c:
        print("  /health   ", c.get(f"{url}/health", timeout=3).json())
        info = c.get(f"{url}/mesh/info", timeout=3).json()
        print("  /mesh/info", {k: info[k] for k in ("device", "tier", "model", "max_num_tokens", "load")})

        print("\n3. chat with a tool")
        sid = f"phone-check-{int(time.time())}"
        msgs = [{"role": "system", "content": "You are a phone assistant. Use tools when they help."},
                {"role": "user", "content": "How much battery do I have left?"}]
        body = {"model": info["model"], "messages": msgs, "tools": TOOLS, "session_id": sid, "max_tokens": 200}
        t0 = time.time()
        r = c.post(f"{url}/v1/chat/completions", json=body).json()
        msg = r["choices"][0]["message"]
        print(f"  → {json.dumps(msg)[:300]}   ({time.time() - t0:.1f} s, mesh={r.get('mesh')})")
        calls = msg.get("tool_calls") or []
        if not calls:
            print("  the model answered without the tool (fine, but expected a get_battery call)")
            return 0
        msgs.append(msg)
        for call in calls:
            result = json.dumps({"percent": 62, "charging": False})      # the app would read the real value
            msgs.append({"role": "tool", "tool_call_id": call["id"], "content": result})
            print(f"  tool  {call['function']['name']}({call['function']['arguments']}) → {result}")
        t0 = time.time()
        r = c.post(f"{url}/v1/chat/completions", json={**body, "messages": msgs}).json()
        print(f"  ← {r['choices'][0]['message']['content']!r}   ({time.time() - t0:.1f} s, reused cache: {r['mesh'].get('reused')})")
    print("\nok: this is everything the app needs from the Mac's node")
    return 0


if __name__ == "__main__":
    sys.exit(main())
