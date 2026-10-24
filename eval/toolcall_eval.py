"""Tool-calling eval for the Gem Mesh.

Gives one LiteRT-LM model seven stub tools and a set of tasks, lets the engine
run its automatic tool loop, and scores the recorded calls against what a
correct agent would do: right tool, right arguments, no tool when none is
needed, and the right sequence for two-step tasks.

    uv run --python 3.12 --with litert-lm==0.18.1 toolcall_eval.py gemma4-26b
"""
import sys, time, pathlib, json
import litert_lm
from litert_lm import interfaces

MODEL_ID = sys.argv[1] if len(sys.argv) > 1 else "gemma4-12b-gpu"
MODEL_PATH = pathlib.Path.home() / ".litert-lm" / "models" / MODEL_ID / "model.litertlm"

CALLS: list[tuple[str, dict]] = []

def read_file(path: str) -> str:
    """Read a text file from the user's workspace.

    Args:
        path: Relative path of the file to read.
    """
    CALLS.append(("read_file", {"path": path}))
    return "port: 8080\naction items:\n- send slides to Dana\n- book the room for Friday\n"

def search_documents(query: str, top_k: int = 5) -> str:
    """Search the firm's internal document index.

    Args:
        query: Search terms.
        top_k: Number of results to return.
    """
    CALLS.append(("search_documents", {"query": query, "top_k": top_k}))
    return "1. Vacation policy v3: 20 days per year, requests go through the HR portal two weeks ahead."

def send_email(to: str, subject: str, body: str) -> str:
    """Send an email on the user's behalf.

    Args:
        to: Recipient email address.
        subject: Subject line.
        body: Plain-text body.
    """
    CALLS.append(("send_email", {"to": to, "subject": subject, "body": body}))
    return "sent"

def get_weather(city: str) -> str:
    """Get the current weather and tomorrow's forecast for a city.

    Args:
        city: City name.
    """
    CALLS.append(("get_weather", {"city": city}))
    return f"{city}: 12 C, overcast now. Tomorrow: rain expected."

def calculator(expression: str) -> str:
    """Evaluate an arithmetic expression exactly.

    Args:
        expression: The arithmetic expression, e.g. "2 * (3 + 4)".
    """
    CALLS.append(("calculator", {"expression": expression}))
    try:
        return str(eval(expression, {"__builtins__": {}}, {}))
    except Exception as e:
        return f"error: {e}"

def open_url(url: str) -> str:
    """Open a web page in the browser and return its text.

    Args:
        url: Full URL including scheme.
    """
    CALLS.append(("open_url", {"url": url}))
    return "Quarterly report: revenue up 8%, churn down 1.2 points, hiring paused."

def create_calendar_event(title: str, date: str, time: str) -> str:
    """Create a calendar event.

    Args:
        title: Event title.
        date: Date as YYYY-MM-DD.
        time: Start time as HH:MM, 24-hour.
    """
    CALLS.append(("create_calendar_event", {"title": title, "date": date, "time": time}))
    return "created"

TOOLS = [read_file, search_documents, send_email, get_weather, calculator, open_url, create_calendar_event]

# (prompt, expected calls in order). Each expected call: (name, {arg: check}) where check is
# a string that must appear case-insensitively in the arg, or a non-string compared exactly.
# An empty list means no tool should be called.
TASKS = [
    ("What's the weather in Tokyo right now?", [("get_weather", {"city": "tokyo"})]),
    ("Read the file notes/meeting.md and tell me the action items.", [("read_file", {"path": "notes/meeting.md"})]),
    ("What is 1234 * 5678? Use the calculator.", [("calculator", {"expression": "1234"})]),
    ("Email bob@example.com with subject 'Lunch' saying 'See you at noon.'", [("send_email", {"to": "bob@example.com", "subject": "lunch"})]),
    ("Search our documents for the vacation policy.", [("search_documents", {"query": "vacation"})]),
    ("Open https://example.com/report and summarize it.", [("open_url", {"url": "https://example.com/report"})]),
    ("Schedule a meeting called 'Design review' on 2026-10-24 at 15:00.", [("create_calendar_event", {"title": "design review", "date": "2026-10-24", "time": "15:00"})]),
    ("Write a haiku about rain.", []),
    ("Explain what a mutex is in two sentences.", []),
    ("Find the vacation policy in our docs, then email a one-line summary of it to hr@example.com with subject 'Vacation policy'.",
     [("search_documents", {"query": "vacation"}), ("send_email", {"to": "hr@example.com", "subject": "vacation policy"})]),
    ("Read config/settings.yaml and tell me the port number.", [("read_file", {"path": "config/settings.yaml"})]),
    ("What's the weather in Paris and in Berlin?", [("get_weather", {"city": "paris"}), ("get_weather", {"city": "berlin"})]),
    ("Compute 15% of 2340 with the calculator.", [("calculator", {"expression": "2340"})]),
    ("Translate 'good morning' to French.", []),
    ("Check the weather in Seattle. If rain is expected tomorrow, create a calendar event 'Bring umbrella' on 2026-10-22 at 08:00.",
     [("get_weather", {"city": "seattle"}), ("create_calendar_event", {"title": "umbrella", "date": "2026-10-22"})]),
    ("Search the docs for 'onboarding checklist' and return only the top 3 results.", [("search_documents", {"query": "onboarding", "top_k": 3})]),
]

def arg_ok(actual, check) -> bool:
    if isinstance(check, str):
        return isinstance(actual, str) and check.lower() in actual.lower()
    try:
        return type(check)(actual) == check
    except Exception:
        return False

def score(expected, calls):
    """Return (passed, note). Expected calls must appear in order as a subsequence."""
    if not expected:
        return (len(calls) == 0, "no tool needed" if not calls else f"hallucinated {[c[0] for c in calls]}")
    i = 0
    for name, args in calls:
        if i < len(expected) and name == expected[i][0] and all(arg_ok(args.get(k), v) for k, v in expected[i][1].items()):
            i += 1
    # allow any order for the two-city weather task
    if i < len(expected) and all(e[0] == expected[0][0] for e in expected):
        hits = [any(c[0] == e[0] and all(arg_ok(c[1].get(k), v) for k, v in e[1].items()) for c in calls) for e in expected]
        if all(hits):
            i = len(expected)
    if i == len(expected):
        extra = len(calls) - len(expected)
        return (True, "ok" if extra <= 0 else f"ok, {extra} extra call(s)")
    got = [(n, {k: (str(v)[:30]) for k, v in a.items()}) for n, a in calls]
    return (False, f"wanted {[e[0] for e in expected]} got {got}")

def main():
    t0 = time.time()
    engine = litert_lm.Engine(model_path=str(MODEL_PATH), backend=interfaces.Backend.GPU(), max_num_tokens=4096)
    init_s = time.time() - t0
    passed = 0
    lat = []
    rows = []
    for prompt, expected in TASKS:
        CALLS.clear()
        t1 = time.time()
        err = ""
        final = ""
        try:
            with engine.create_conversation(
                messages=[{"role": "system", "content": "You are a helpful assistant with tools. Use a tool when the task needs one; answer directly when it does not."}],
                tools=TOOLS,
                automatic_tool_calling=True,
                thinking_config=interfaces.ThinkingConfig(enable_thinking=False, thinking_token_budget=0),
                sampler_config=interfaces.SamplerConfig(temperature=0.0, top_k=1, top_p=1.0),
                max_output_tokens=256,
            ) as conv:
                out = conv.send_message(prompt)
                final = str(getattr(out, "contents", out))[:70].replace("\n", " ")
        except Exception as e:  # keep going; a crash is a failure for that task
            err = f"{type(e).__name__}: {str(e)[:80]}"
        dt = time.time() - t1
        lat.append(dt)
        ok, note = score(expected, list(CALLS))
        if err:
            ok, note = False, err
        passed += ok
        rows.append((ok, dt, prompt[:58], note, final))
    lat_sorted = sorted(lat)
    print(f"\n=== {MODEL_ID} ===")
    print(f"engine init {init_s:.1f}s   tasks {len(TASKS)}   passed {passed}/{len(TASKS)}   "
          f"median {lat_sorted[len(lat)//2]:.2f}s   max {lat_sorted[-1]:.2f}s")
    for ok, dt, prompt, note, final in rows:
        print(f"{'ok ' if ok else 'XX '} {dt:5.2f}s  {prompt!r:<62} {note}")
        if not ok and final:
            print(f"          final text: {final!r}")
    engine.close()

if __name__ == "__main__":
    main()
