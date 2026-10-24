"""Write policy/golden/*.json: language-neutral cases every router must pass (the Python one and the Android port).

Run after changing policy/rules.yaml or policy/tiers.yaml:  uv run python eval/make_golden.py
Check an implementation against them:                       uv run python eval/test_golden.py
The expected values come from the Python router, so a regeneration is a deliberate policy change: review the diff.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "core"))
from meshcore.nodes import NodeInfo           # noqa: E402
from meshcore.policy import load_policy       # noqa: E402
from meshcore.router import classify_rules, route  # noqa: E402

POL = load_policy(ROOT / "policy")
OUT = ROOT / "policy" / "golden"

PRIVACY = [
    # (text, why it is here)
    ("What is 12 times 7?", "plain public question"),
    ("Explain how a heat pump works.", "plain public question"),
    ("Email bob@example.com about lunch", "email address"),
    ("Call me on +1 415 555 0134 after six", "phone number"),
    ("Summarize the Acme lease", "custom term (client name)"),
    ("Draft a note to Northwind about the renewal", "custom term"),
    ("read ~/matters/acme/x.pdf", "private path and client"),
    ("Status of case no. 48213?", "case number"),
    ("Current salary $118,000.", "salary with pay word"),
    ("a one-time bonus of $5,000", "bonus"),
    ("She earns 85k", "salary shorthand"),
    ("paid $28 per hour", "hourly pay"),
    ("The Tenant shall pay the initial annual Rent of $684,000 yearly in advance", "rent is not a salary"),
    ("Amount due by 15 November 2026: $3,900.00", "invoice total is not a salary"),
    ("payment of the Landlord's out-of-hours charge of $180 per hour", "a building charge is not pay"),
    ("Tickets cost $25 each", "price"),
    ("my api key is sk-ant-abc123def456ghi789jkl", "secret key"),
]

N = {
    "phone": dict(device="phone", tier="T0", model="gemma4-e4b", local=True),
    "mac": dict(device="mac", tier="T1", model="gemma4-26b"),
    "ws": dict(device="ws", tier="T2", model="gemma4-26b"),
}
LONG = "x " * 4000      # ~2,000 tokens
HEAVY = "x " * 8000     # ~4,000 tokens (above heavy_tokens 3000)
ROUTING = [
    # (name, prompt, nodes, context_tokens)
    ("short public, phone and laptop → phone", "What is 12 times 7?", ["phone", "mac"], 0),
    ("short sensitive → phone", "Email bob@example.com about lunch", ["phone", "mac", "ws"], 0),
    ("client term, laptop and workstation → laptop", "Summarize the Acme lease", ["mac", "ws"], 0),
    ("long → laptop", LONG, ["phone", "mac", "ws"], 0),
    ("heavy → workstation", HEAVY, ["phone", "mac", "ws"], 0),
    ("heavy, no workstation → laptop (the demo setup)", HEAVY, ["phone", "mac"], 0),
    ("heavy, phone alone → queue", HEAVY, ["phone"], 0),
    ("long, phone alone → queue", LONG, ["phone"], 0),
    ("short question, phone alone → phone", "Remind me what Mia likes", ["phone"], 0),
    ("short prompt with a long conversation → laptop", "and the break clause?", ["phone", "mac"], 2500),
]


def node(key: str) -> NodeInfo:
    d = N[key]
    return NodeInfo(name=key, device=d["device"], tier=d["tier"], model=d["model"],
                    base_url=None if d.get("local") else f"http://{key}:9400", latency_ms=5.0)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    privacy = []
    for text, why in PRIVACY:
        label, hits = classify_rules(text, POL)
        rules = sorted({h.rsplit("(", 1)[1].rstrip(")") for h in hits})
        privacy.append({"text": text, "why": why, "expect": {"privacy": label, "rules": rules}})
    (OUT / "privacy.json").write_text(json.dumps({
        "about": "Rules only (rules.yaml): no classifier. 'rules' lists the rule names that fire; 'custom term' means a term from rules.yaml terms.",
        "cases": privacy}, indent=2) + "\n")
    routing = []
    for name, prompt, nodes, ctx in ROUTING:
        d = route(prompt, [node(k) for k in nodes], POL, context_tokens=ctx)
        routing.append({"name": name, "prompt": prompt if len(prompt) < 200 else {"repeat": "x ", "times": len(prompt) // 2},
                        "context_tokens": ctx, "nodes": [N[k] | {"key": k} for k in nodes],
                        "expect": {"privacy": d.privacy, "chosen": d.chosen.device if d.chosen else None,
                                   "queue_needs": d.needs, "floor": d.floor, "ceiling": d.ceiling}})
    (OUT / "routing.json").write_text(json.dumps({
        "about": "Router decisions with the classifier off. Token estimate: len(text) // 4. Nodes all reachable, load 0. "
                 "chosen null means the request is queued until a node of tier queue_needs or higher is reachable.",
        "cases": routing}, indent=2) + "\n")
    print(f"wrote {len(privacy)} privacy and {len(routing)} routing cases to {OUT}")


if __name__ == "__main__":
    main()
