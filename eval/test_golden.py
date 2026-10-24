"""Check the Python router against policy/golden/*.json (the Android port runs the same files in its unit tests)."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "core"))
from meshcore.nodes import NodeInfo           # noqa: E402
from meshcore.policy import load_policy       # noqa: E402
from meshcore.router import classify_rules, route  # noqa: E402

POL = load_policy(ROOT / "policy")
G = ROOT / "policy" / "golden"
fails = total = 0
for c in json.loads((G / "privacy.json").read_text())["cases"]:
    label, hits = classify_rules(c["text"], POL)
    rules = sorted({h.rsplit("(", 1)[1].rstrip(")") for h in hits})
    ok = label == c["expect"]["privacy"] and rules == c["expect"]["rules"]
    total += 1; fails += not ok
    if not ok:
        print(f"XX privacy {c['text'][:60]!r}: got {label} {rules}, want {c['expect']}")
for c in json.loads((G / "routing.json").read_text())["cases"]:
    p = c["prompt"]
    prompt = p if isinstance(p, str) else p["repeat"] * p["times"]
    nodes = [NodeInfo(name=n["key"], device=n["device"], tier=n["tier"], model=n["model"],
                      base_url=None if n.get("local") else f"http://{n['key']}:9400", latency_ms=5.0) for n in c["nodes"]]
    d = route(prompt, nodes, POL, context_tokens=c["context_tokens"])
    got = {"privacy": d.privacy, "chosen": d.chosen.device if d.chosen else None, "queue_needs": d.needs,
           "floor": d.floor, "ceiling": d.ceiling}
    ok = got == c["expect"]
    total += 1; fails += not ok
    if not ok:
        print(f"XX routing {c['name']}: got {got}, want {c['expect']}")
print(f"{total - fails}/{total} golden cases pass")
sys.exit(1 if fails else 0)
