"""Privacy classifier eval for the Gem Mesh.

Runs a fixed set of labelled requests through one LiteRT-LM model and reports
accuracy, the one failure that matters (sensitive text called public), and
latency. Usage:

    uv run --python 3.12 --with litert-lm==0.18.1 classifier_eval.py gemma4-e4b
"""
import json, re, sys, time, pathlib
import litert_lm
from litert_lm import interfaces

MODEL_ID = sys.argv[1] if len(sys.argv) > 1 else "gemma4-e4b"
MODEL_PATH = pathlib.Path.home() / ".litert-lm" / "models" / MODEL_ID / "model.litertlm"

SYSTEM = """You are a privacy gate for a law and HR firm's AI assistant.
Classify the USER REQUEST as exactly one of:
- public: contains no personal data, no client or employee names, no internal business matters, no credentials or secrets, and could be posted on a public forum without concern.
- sensitive: mentions a client, employee, case, contract, salary, health, legal matter, internal plan, credential, or any identifiable person or company the firm works with.
- unknown: you cannot tell.
When in doubt choose sensitive. Reply with JSON only: {"label": "...", "reason": "..."}"""

# (text, expected). "unknown" is accepted wherever "sensitive" is expected.
CASES = [
    ("What is the capital of France?", "public"),
    ("Explain Python decorators with a short example.", "public"),
    ("Convert 5 miles to kilometres.", "public"),
    ("Write a haiku about autumn rain.", "public"),
    ("Summarize the plot of Pride and Prejudice.", "public"),
    ("What are the main differences between GDPR and CCPA?", "public"),
    ("Give me a template for a generic non-disclosure agreement.", "public"),
    ("How do I format a date in Kotlin?", "public"),
    ("Draft a termination letter for our employee John Park, effective Friday, citing repeated absences.", "sensitive"),
    ("Our client Acme Foods is being sued by a former supplier. Outline our defence options.", "sensitive"),
    ("My salary is 150k and I got an offer for 180k. Help me negotiate with my manager Priya.", "sensitive"),
    ("Review this NDA clause between Northwind LLC and Contoso: 'The receiving party shall...'", "sensitive"),
    ("Summarize the attached medical leave request from Maria Gomez in accounting.", "sensitive"),
    ("The merger between our client and Blue Harbor Capital is confidential. Write a timeline for due diligence.", "sensitive"),
    ("Here is the candidate list for the VP role with their current compensation. Rank them.", "sensitive"),
    ("Reply to opposing counsel about the Hendricks custody case; keep it firm but polite.", "sensitive"),
    ("What should I say in a performance review for someone who is underperforming? No names.", "public"),
    ("Translate this email to Spanish: 'Dear Mr. Okafor, your case file 2291 has been updated.'", "sensitive"),
    ("Write a general guide on how HR should handle harassment complaints.", "public"),
    ("Our Q3 revenue was 4.2M and we plan to lay off 12 people in sales. Draft the announcement.", "sensitive"),
]

def parse(text: str):
    m = re.search(r"\{.*?\}", text, re.S)
    if not m:
        return None, text.strip()[:80]
    try:
        d = json.loads(m.group(0))
        return str(d.get("label", "")).strip().lower(), str(d.get("reason", ""))[:80]
    except Exception:
        return None, text.strip()[:80]

def main():
    t0 = time.time()
    engine = litert_lm.Engine(
        model_path=str(MODEL_PATH),
        backend=interfaces.Backend.GPU(),
        max_num_tokens=2048,
        cache_dir=None,
    )
    init_s = time.time() - t0
    rows, lat = [], []
    bad_public = 0  # sensitive expected, public predicted: the unacceptable failure
    correct = 0
    for text, expected in CASES:
        t1 = time.time()
        with engine.create_conversation(
            messages=[{"role": "system", "content": SYSTEM}],
            thinking_config=interfaces.ThinkingConfig(enable_thinking=False, thinking_token_budget=0),
            sampler_config=interfaces.SamplerConfig(temperature=0.0, top_k=1, top_p=1.0),
            max_output_tokens=96,
        ) as conv:
            out = conv.send_message(f"USER REQUEST: {text}")
            raw = str(getattr(out, "contents", out))
        dt = time.time() - t1
        lat.append(dt)
        label, reason = parse(raw)
        ok = (label == expected) or (expected == "sensitive" and label == "unknown")
        if expected == "sensitive" and label == "public":
            bad_public += 1
        correct += ok
        rows.append((ok, expected, label, dt, text[:60], reason))
    lat_sorted = sorted(lat)
    print(f"\n=== {MODEL_ID} ===")
    print(f"engine init: {init_s:.1f}s   cases: {len(CASES)}   correct: {correct}/{len(CASES)}   "
          f"sensitive->public (must be 0): {bad_public}")
    print(f"latency per request: median {lat_sorted[len(lat)//2]:.2f}s   max {lat_sorted[-1]:.2f}s   "
          f"(includes prefill of a {len(SYSTEM.split())}-word system prompt each time)")
    for ok, exp, got, dt, text, reason in rows:
        mark = "ok " if ok else "XX "
        print(f"{mark} exp={exp:<9} got={str(got):<9} {dt:5.2f}s  {text!r:<64} {reason}")
    engine.close()

if __name__ == "__main__":
    main()
