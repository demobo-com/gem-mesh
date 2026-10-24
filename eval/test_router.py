"""Router unit tests: no models needed. Run: uv run python eval/test_router.py"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "core"))
from meshcore.nodes import NodeInfo
from meshcore.policy import load_policy
from meshcore.router import classify_rules, route

POL = load_policy(Path(__file__).resolve().parents[1] / "policy")
PHONE = NodeInfo("local", "phone", "T0", "gemma4-e4b", base_url=None)
MAC = NodeInfo("m", "mac", "T1", "gemma4-26b", base_url="http://m")
WS = NodeInfo("w", "ws", "T2", "gemma4-31b", base_url="http://w")
LONG = "x " * 4000          # ~2,000 tokens  → long
HEAVY = "x " * 30000        # ~15,000 tokens → heavy

cases = [
    ("short public, phone+mac", "What is 12 times 7?", [PHONE, MAC], "phone", "public"),
    ("short sensitive stays lowest", "Email bob@example.com about lunch", [PHONE, MAC, WS], "phone", "sensitive"),
    ("custom term", "Summarize the Acme lease", [MAC, WS], "mac", "sensitive"),
    ("long → T1", LONG, [PHONE, MAC, WS], "mac", "public"),
    ("heavy → T2", HEAVY, [PHONE, MAC, WS], "ws", "public"),
    ("heavy, no T2 → falls back to T1", HEAVY, [PHONE, MAC], "mac", "public"),
    ("heavy, phone only → queue", HEAVY, [PHONE], None, "public"),
    ("long, phone only → queue", LONG, [PHONE], None, "public"),
    ("private path", "read ~/matters/acme/x.pdf", [PHONE], "phone", "sensitive"),
]
fails = 0
d = route("and what about the break clause?", [PHONE, MAC], POL, scan_text="Summarize the Acme lease\nand what about the break clause?")
ok = d.privacy == "sensitive"; fails += not ok
print(f"{'ok ' if ok else 'XX '} {'follow-up after a sensitive turn':<34} → {d.privacy}")
for name, prompt, nodes, want, want_priv in cases:
    d = route(prompt, nodes, POL)
    got = d.chosen.device if d.chosen else None
    ok = got == want and d.privacy == want_priv
    fails += not ok
    print(f"{'ok ' if ok else 'XX '} {name:<34} → {got} ({d.privacy})" + ("" if ok else f"   want {want} ({want_priv})\n      " + "\n      ".join(d.log)))
# The salary rule needs pay words near the amount: rent, invoices and budgets are not salaries.
SALARY = ["Current salary $118,000.", "a one-time bonus of $5,000", "She earns 85k", "offer was $140k base",
          "his $95,000 salary", "we offered 120k plus equity", "raise to $130,000", "severance of $40,000",
          "paid $28 per hour", "her hourly wage is $31.50 an hour"]
NOT_SALARY = ["The Tenant shall pay the initial annual Rent of $684,000 yearly in advance", "Amount due by 15 November 2026: $3,900.00",
              "Subtotal: $6,400.00", "a 5k run", "budget $1,200 for training", "The deal is worth $2,500,000",
              "Rent of $684,000 per year, with a service charge", "6.5 h at $640/h: $4,160.00", "Tickets cost $25 each",
              "payment of the Landlord's out-of-hours charge of $180 per hour", "$45/hr contractor via the agency"]
checks = 0
for text in SALARY + NOT_SALARY:
    hit = any("(salary)" in h for h in classify_rules(text, POL)[1])
    ok = hit == (text in SALARY); fails += not ok; checks += 1
    if not ok:
        print(f"XX  salary rule {'missed' if text in SALARY else 'false hit'}: {text}")
print(f"ok  salary rule on {checks} phrasings")
print(f"\n{len(cases)+1+checks-fails}/{len(cases)+1+checks} passed")
sys.exit(1 if fails else 0)
