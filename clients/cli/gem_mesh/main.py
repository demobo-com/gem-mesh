"""gem-mesh / gem-mesh-mobile command line."""
from __future__ import annotations

import argparse
import sys

from .session import AMBER, BLUE, BOLD, DIM, GREEN, RESET, ClientSession


def print_header(s: ClientSession) -> None:
    net = s.network()
    print(f"{DIM}net    {net.describe()} ({net.detail}){RESET}")
    print(f"{DIM}mesh   {s.mesh_line()}{RESET}")
    phones = s.table.memory_peers()     # phones serve memory only, never chat, so they are not in the mesh line
    if phones:
        line = "   ".join(f"{d} memory {u.split('//')[-1]}" for d, u in phones)
        print(f"{DIM}phone  {line}{RESET}")



COMMANDS = ["/help", "/tier", "/nodes", "/reset", "/remember", "/recall", "/facts", "/forget", "/index", "/memory", "/sync",
            "/file", "/hide", "/unhide", "/network", "/queue", "/think", "/frontier", "/phone"]


def enable_line_editing(name: str) -> None:
    """Arrow keys, Ctrl-R search, in-line editing and history across restarts (like a shell), Tab completes /commands."""
    try:
        import atexit
        import readline
        from meshcore.profile import MESH_HOME
    except Exception:
        return
    hist = MESH_HOME / f"history-{name}"
    try:
        hist.parent.mkdir(parents=True, exist_ok=True)
        if hist.exists():
            readline.read_history_file(str(hist))
    except OSError:
        pass
    readline.set_history_length(2000)
    atexit.register(lambda: readline.write_history_file(str(hist)))

    def complete(text, state):
        opts = [c for c in COMMANDS if c.startswith(text)] if text.startswith("/") else []
        return opts[state] if state < len(opts) else None
    readline.set_completer(complete)
    readline.set_completer_delims(" \t\n")
    if "libedit" in (readline.__doc__ or ""):
        readline.parse_and_bind("bind ^I rl_complete")
    else:
        readline.parse_and_bind("tab: complete")

def run_chat(s: ClientSession, show_log: bool = True) -> int:
    enable_line_editing(s.profile.role)
    import threading as _th, time as _tm

    def _drain_loop():
        while True:
            _tm.sleep(10)
            try:
                s.drain_queue(notify=queue_notice)
            except Exception:
                pass
    _th.Thread(target=_drain_loop, daemon=True).start()
    print(f"{BOLD}{s.profile.role}{RESET} as {s.profile.device} · {s.profile.tier} · session {s.session_id} · tier {s.prefer_tier or 'auto'} · /help · Ctrl-D to quit")
    s.table.wait(1.5)
    print_header(s)
    if s.memory:
        st = s.memory.stats()
        print(f"{DIM}{s.memory_note} · {st['events']} items ({', '.join(f'{k} {v}' for k, v in st['by_kind'].items()) or 'empty'}){RESET}")
    while True:
        try:
            prompt = input(f"\n\001{BLUE}\002›\001{RESET}\002 ").strip()
        except (EOFError, KeyboardInterrupt):
            print(); break
        if not prompt:
            continue
        if prompt in ("/nodes", "/mesh"):
            s.table.refresh(); print_header(s); continue
        if prompt == "/reset":
            s.transcript.clear(); print(f"{DIM}transcript cleared{RESET}"); continue
        if prompt.startswith(("/remember", "/recall", "/facts", "/forget", "/memory", "/sync", "/index")):
            memory_command(s, prompt); continue
        if prompt.startswith("/frontier"):
            frontier(s, prompt[9:].strip()); continue
        if prompt.startswith("/phone"):
            phone(s, prompt[6:].strip()); continue
        if prompt.startswith("/think"):
            arg = prompt[6:].strip().lower()
            s.think_override = True if arg == "on" else False if arg == "off" else None
            print(f"{DIM}thinking: {'on' if s.think_override else 'off' if s.think_override is False else 'per tier (' + ', '.join(f'{k} {v}' for k, v in s.policy.effort.items()) + ')'}{RESET}"); continue
        if prompt.startswith("/queue"):
            if prompt[6:].strip() == "clear":
                db = s._queue_db(); db.execute("DELETE FROM tasks WHERE status='done'"); db.commit()
            rows = s.queue_list()
            if not rows:
                print(f"{DIM}queue is empty{RESET}")
            for tid, status, needs, node, p, res, created in rows:
                print(f"{DIM}#{tid:<3} {status:<8} needs {needs:<3} {('on ' + node) if node else '':<14} {p!r}{RESET}")
                if res:
                    print(f"       {res[:160]}")
            continue
        if prompt.startswith("/hide"):
            import os
            dev = prompt[5:].strip()
            hidden = {d for d in os.environ.get("MESH_IGNORE", "").split(",") if d}
            if dev:
                hidden.add(dev)
            os.environ["MESH_IGNORE"] = ",".join(sorted(hidden))
            print(f"{DIM}hidden from routing: {', '.join(sorted(hidden)) or 'nothing'}  (/unhide to restore){RESET}"); print_header(s); continue
        if prompt.startswith("/unhide"):
            import os
            os.environ["MESH_IGNORE"] = ""
            print(f"{DIM}all nodes visible again{RESET}"); print_header(s); continue
        if prompt.startswith("/network"):
            mode = prompt[8:].strip().lower()
            if mode in ("office", "airplane", "offline"):
                s.network_override = mode
            elif mode in ("", "auto"):
                s.network_override = None
            else:
                print(f"{DIM}usage: /network office|airplane|offline|auto{RESET}"); continue
            print_header(s); continue
        if prompt.startswith("/file"):
            parts = prompt[5:].strip().split(" ", 1)
            from pathlib import Path
            path = Path(parts[0]).expanduser() if parts and parts[0] else None
            if not path or not path.is_file():
                print(f"{DIM}usage: /file <path> <question>{RESET}"); continue
            prompt = with_files(parts[1] if len(parts) > 1 else "Summarize this file.", [str(path)])
            print(f"{DIM}attached {path.name} ({len(prompt)//4:,} tokens){RESET}")
        if prompt.startswith("/tier"):
            arg = prompt[5:].strip().upper()
            if arg in ("T0", "T1", "T2", "T3"):
                s.prefer_tier = arg; print(f"{DIM}preferring {arg} or higher when reachable; falls back within the window{RESET}")
            elif arg in ("", "AUTO"):
                s.prefer_tier = None; print(f"{DIM}tier: automatic (lowest tier that fits){RESET}")
            else:
                print(f"{DIM}usage: /tier T0|T1|T2|T3|auto   (now: {s.prefer_tier or 'auto'}){RESET}")
            continue
        if prompt in ("/help", "/?"):
            print(f"{DIM}/tier T0|T1|T2|T3|auto   prefer a tier from now on\n/nodes                    show reachable nodes\n/reset                    clear the conversation\n/remember <fact>          save a fact to memory\n/recall <query>           search memory\n/facts                    what memory holds about you, numbered\n/forget <n>               forget fact n, on every device\n/index <file>             add a document to memory\n/memory                   memory status\n/sync                     sync memory with the phone now\n/file <path> <question>   ask about a file (sent with the question)\n                          files in demo/files are attached just by naming them\n/hide <device>            simulate a node going away; /unhide restores\n/network office|airplane|offline|auto   force the network mode\n/queue [clear]            tasks waiting for a bigger machine\n/think on|off|auto        reasoning before answering (default: on for T2/T3)\n/frontier <question>      ask Gemini, public conversations only, after you approve\n/phone <task>             AGI's agent does it on your phone (it sees the screen), after you approve\nCtrl-D                    quit{RESET}"); continue
        if not prompt.startswith("/"):
            prompt, attached = attach_mentions(prompt)
            if attached:
                print(f"{DIM}attached {', '.join(attached)} ({len(prompt)//4:,} tokens){RESET}")
        decision = s.decide(prompt)
        if show_log:
            for line in decision.log:
                print(f"{DIM}{line}{RESET}")
        if not decision.chosen:
            tid = s.enqueue(prompt, decision.needs)
            print(f"{AMBER}queue  nothing reachable can take this (needs {decision.needs}); saved as task #{tid}. "
                  f"It runs by itself when a {decision.needs}+ machine is back; /queue to see it.{RESET}")
            continue
        print()
        ans = s.ask(prompt, on_token=lambda t: print(t, end="", flush=True), on_tool=show_tool, approve=approve_change)
        mem_lines = len([l for l in s.last_memory.splitlines() if l.startswith("- ")])
        print(f"\n\n{DIM}{ans.badge}" + (f" · used {mem_lines} memory item(s)" if mem_lines else "") + f"{RESET}")
    s.close()
    return 0


def with_files(prompt: str, files: list[str]) -> str:
    from pathlib import Path
    from .files import read_any
    parts = [prompt]
    for f in files:
        p = Path(f).expanduser()
        parts.append(f"\n\n--- file: {p.name} ---\n{read_any(p, max_chars=10**7)}")
    return "".join(parts)


def approve_change(plan) -> bool:
    """Show exactly what a file action will do, then ask. Default is no."""
    print(f"\n{AMBER}change  {plan.summary}{RESET}")
    for line in (plan.preview or "").splitlines()[:16]:
        print(f"{DIM}  │ {line[:150]}{RESET}")
    try:
        return input("  apply? [y/N] ").strip().lower() in ("y", "yes")
    except EOFError:
        return False




def show_tool(name: str, args: dict, result: str) -> None:
    arg = args.get("query") or args.get("url") or ""
    where = ("left the mesh" if name in ("web_search", "fetch") and not result.startswith(("Blocked", "Web limit", "Failed", "Error"))
             else "→ " + arg if name == "escalate" else "on device")
    from .files import ACTION_TOOLS
    if name in ACTION_TOOLS:
        ok = result.startswith("Done")
        print(f"{(GREEN if ok else AMBER)}change  {result[:400]}{RESET}", flush=True)
        return
    if name == "look_at_image":
        print(f"\n{DIM}tool   look_at_image {args.get('name', '')} → on device (vision){RESET}", flush=True)
        return
    if name in ("list_files", "read_file"):
        print(f"\n{DIM}tool   {name}{(' ' + args.get('name')) if args.get('name') else ''} → on device{RESET}", flush=True)
        return
    if name == "remember":
        if result == "Saved.":
            print(f"\n{DIM}memory remembered: {args.get('fact', '')[:120]}{RESET}", flush=True)
        return
    if name == "escalate":
        print(f"\n{DIM}route  web question handed up the mesh {where}{RESET}", flush=True); return
    first = result.strip().splitlines()[0][:90] if result.strip() else ""
    print(f"\n{DIM}tool   {name} \"{arg[:70]}\" → {where} · {first}{RESET}", flush=True)


def frontier(s: ClientSession, question: str) -> None:
    """Send one public question to the frontier model (Gemini) after showing exactly what leaves and asking."""
    import os
    from meshcore.router import classify_rules
    if not question:
        print(f"{DIM}usage: /frontier <question>{RESET}"); return
    if s.policy.frontier == "never":
        print(f"{AMBER}frontier  off by policy (frontier: never){RESET}"); return
    convo = "\n".join(str(m.get("content", "")) for m in s.transcript if m.get("role") == "user")
    scan = (convo + "\n" + question).strip()
    label, hits = classify_rules(scan, s.policy)
    why = "; ".join(hits[:2])
    if label == "public" and s.policy.classifier:
        label, why = s.classify(scan)
    if label != "public":
        print(f"{AMBER}frontier  refused: this conversation is {label} ({why[:100]}). Nothing was sent.{RESET}")
        print(f"{DIM}          /reset starts a clean conversation if the question really is public.{RESET}"); return
    print(f"{AMBER}frontier  this exact text would leave your devices for Google Gemini:{RESET}\n  {question}")
    try:
        yes = input("  send it? [y/N] ").strip().lower() in ("y", "yes")
    except EOFError:
        yes = False
    if not yes:
        print(f"{DIM}frontier  kept local, nothing sent{RESET}"); return
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        print(f"{AMBER}frontier  no GEMINI_API_KEY set; nothing sent. Add the key to use this tier.{RESET}"); return
    import httpx, time as _t
    model = os.environ.get("MESH_GEMINI_MODEL", "gemini-2.5-flash")
    t0 = _t.time()
    try:
        r = httpx.post(f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
                       headers={"x-goog-api-key": key}, json={"contents": [{"parts": [{"text": question}]}]}, timeout=60)
        r.raise_for_status()
        text = "".join(p.get("text", "") for p in r.json()["candidates"][0]["content"]["parts"])
    except Exception as ex:
        print(f"{AMBER}frontier  call failed: {ex}{RESET}"); return
    print(f"\n{text}\n\n{DIM}badge  frontier · {model} · {len(question.encode())} bytes left the mesh (approved) · {_t.time()-t0:.1f} s{RESET}")
    s.transcript += [{"role": "user", "content": question}, {"role": "assistant", "content": text}]


def phone(s: ClientSession, task: str) -> None:
    """Hand one task to AGI's phone agent after showing exactly what leaves (the task, then the phone's screen) and asking."""
    import os
    import time as _t
    from meshcore.router import classify_rules
    from .phone import PhoneAgent, PhoneAgentError
    if not task:
        print(f"{DIM}usage: /phone <task>   e.g. /phone open Settings and tell me the battery level{RESET}"); return
    # Only the task leaves as text, so only the task is checked; the conversation stays out of it. A private task is
    # not refused here (operating the phone often needs names and addresses): the user sees why and decides.
    label, hits = classify_rules(task, s.policy)
    why = "; ".join(hits[:2])
    if label == "public" and s.policy.classifier:
        label, why = s.classify(task)
    print(f"{AMBER}phone     this exact task would go to AGI, whose agent then taps and types on your phone:{RESET}\n  {task}")
    if label != "public":
        print(f"{AMBER}          checked as {label} ({why[:100]}): it leaves your devices anyway if you say yes{RESET}")
    print(f"{DIM}          a screenshot of every step goes to AGI too, with anything on the screen · about $0.01 a step, at most 200{RESET}")
    try:
        yes = input("  let it? [y/N] ").strip().lower() in ("y", "yes")
    except EOFError:
        yes = False
    if not yes:
        print(f"{DIM}phone     kept local, nothing sent{RESET}"); return
    key = os.environ.get("AGI_API_KEY")
    if not key:
        print(f"{AMBER}phone     no AGI_API_KEY set; nothing sent. Add the key from platform.agi.tech to use this.{RESET}"); return
    t0 = _t.time()
    print(f"{DIM}phone     working · Ctrl-C stops it{RESET}", flush=True)
    try:
        r = PhoneAgent(key).run(task, on_steps=lambda n: print(f"\r{DIM}phone     step {n}{RESET}", end="", flush=True))
    except Exception as ex:
        print(f"\n{AMBER}phone     failed: {ex if isinstance(ex, PhoneAgentError) else f'{type(ex).__name__}: {ex}'}{RESET}"); return
    # needs_user_control also carries the agent's report when it ends on a question.
    ok = r["terminal"] in ("ok", "needs_user_control", "stopped_by_user", "cancelled")
    text = r["summary"] or ("Done." if r["terminal"] == "ok" else r["terminal"])
    print(f"\n\n{text if ok else AMBER + 'phone     ' + text + RESET}\n\n{DIM}badge  phone agent · {r['device']} · {r['steps']} steps · {r['terminal']} · "
          f"the task and {r['steps']} screenshots went to AGI (approved) · {_t.time()-t0:.1f} s{RESET}")
    if ok:
        s.transcript += [{"role": "user", "content": task}, {"role": "assistant", "content": text}]


def queue_notice(tid, node, ans) -> None:
    if node is None:
        print(f"\n{AMBER}queue  task #{tid} {ans}{RESET}", flush=True); return
    first = (ans.text or "").strip().replace("\n", " ")[:300]
    print(f"\n{GREEN}queue  task #{tid} finished on {node.device} / {node.model}:{RESET} {first}\n{DIM}       /queue shows the full list{RESET}", flush=True)

def memory_command(s: ClientSession, line: str) -> None:
    cmd, _, arg = line.partition(" ")
    arg = arg.strip()
    if not s.memory:
        print(f"{DIM}memory is off for this profile{RESET}"); return
    if cmd == "/remember":
        if not arg:
            print(f"{DIM}usage: /remember <fact>{RESET}"); return
        s.memory.append("fact", arg, session=s.session_id); print(f"{DIM}remembered{' (in outbox until the phone is reachable)' if not s.memory.authority else ''}{RESET}")
    elif cmd == "/recall":
        hits = s.memory.search(arg or "", k=6)
        for h in hits:
            print(f"{DIM}{h.score:.2f} {h.kind:<4}{RESET} {h.text[:160]}")
        if not hits:
            print(f"{DIM}nothing found{RESET}")
    elif cmd == "/index":
        from pathlib import Path
        p = Path(arg).expanduser()
        if not p.is_file():
            print(f"{DIM}no such file: {arg}{RESET}"); return
        n = s.memory.add_document(p); print(f"{DIM}indexed {p.name}: {n} chunk(s){RESET}")
    elif cmd == "/facts":
        facts = s.memory.facts()
        for i, f in enumerate(facts, 1):
            print(f"{DIM}{i:>3}  {f['device']:<20}{RESET} {f['text'][:150]}")
        if not facts:
            print(f"{DIM}no facts remembered{RESET}")
    elif cmd == "/forget":
        facts = s.memory.facts()
        if not arg.isdigit() or not 1 <= int(arg) <= len(facts):
            print(f"{DIM}usage: /forget <number from /facts>{RESET}"); return
        f = facts[int(arg) - 1]
        s.memory.forget([f["id"]], f"forgot: {f['text'][:120]}")
        print(f"{DIM}forgot: {f['text'][:120]}" + (" (the phone forgets it at the next sync)" if not s.memory.authority else "") + RESET)
    elif cmd == "/sync":
        r = s.sync_memory()
        print(f"{DIM}{r if r is not None else 'this device is the memory authority; the laptop syncs with it'}{RESET}")
    else:
        st = s.memory.stats()
        print(f"{DIM}{s.memory_note}\n{st['events']} items {st['by_kind']} · from {st['by_device']} · {st['pending']} in outbox · "
              f"{st['vectors']} indexed · {'embeddings on' if st['embedder'] else 'embedding model missing'}\n{st['path']}{RESET}")


def demo_dir():
    """The demo sandbox: <repo>/demo/files, or MESH_FILES_DIR."""
    import os
    from pathlib import Path
    if os.environ.get("MESH_FILES_DIR"):
        return Path(os.environ["MESH_FILES_DIR"]).expanduser()
    here = Path(__file__).resolve()
    for parent in here.parents:
        if (parent / "demo" / "files").is_dir():
            return parent / "demo" / "files"
    from meshcore.profile import MESH_HOME
    return MESH_HOME / "files"


_FILE_NAME = __import__("re").compile(r"[\w.-]+\.(?:txt|md|csv|json|yaml|yml|py|log|pdf)\b")


def attach_mentions(prompt: str) -> tuple[str, list[str]]:
    """Attach any sandbox file mentioned by name in the message."""
    d = demo_dir()
    names = []
    for name in dict.fromkeys(_FILE_NAME.findall(prompt)):
        if (d / name).is_file():
            names.append(name)
    if not names:
        return prompt, []
    return with_files(prompt, [str(d / n) for n in names]), names

def cmd_route(s: ClientSession, prompt: str) -> int:
    settle(s)
    print_header(s)
    d = s.decide(prompt)
    for line in d.log:
        print(line)
    print("summary", d.summary())
    s.close()
    return 0


def settle(s: ClientSession, max_wait: float = 5.0, min_wait: float = 3.0) -> None:
    """Give mDNS discovery time to find every node: wait until the node list stops growing (max 4 s)."""
    import time as _t
    s.table.wait(1.0)
    seen, t0 = len(s.nodes()), _t.time()
    while _t.time() - t0 < max_wait:
        _t.sleep(0.5); s.table.refresh()
        n = len(s.nodes())
        if n == seen and _t.time() - t0 >= min_wait:
            break
        seen = n


def wait_for_phone(s: ClientSession, max_wait: float = 4.0) -> None:
    """One-shot memory commands start before mDNS has answered: give it time to find a phone (max 4 s)."""
    import time as _t
    t0 = _t.time()
    while not s.memory_peers() and _t.time() - t0 < max_wait:
        _t.sleep(0.25)


def cmd_ask(s: ClientSession, prompt: str, show_log: bool, max_tokens: int | None = None) -> int:
    settle(s)
    if show_log:
        print_header(s)
    d = s.decide(prompt)
    if show_log:
        for line in d.log:
            print(f"{DIM}{line}{RESET}")
    if not d.chosen:
        tid = s.enqueue(prompt, d.needs)
        print(f"queue  nothing reachable can take this (needs {d.needs}); saved as task #{tid}, runs when a {d.needs}+ machine is back")
        s.close(); return 4
    ans = s.ask(prompt, on_token=lambda t: print(t, end="", flush=True), max_tokens=max_tokens, on_tool=show_tool,
                approve=approve_change if sys.stdin.isatty() else None)
    print(f"\n{DIM}{ans.badge}{RESET}")
    s.close()
    return 0


def build_parser(prog: str) -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog=prog, description="Thin client for the Gem Mesh")
    ap.add_argument("--network", choices=["office", "airplane", "offline"], help="override detected network mode (scripted demos)")
    ap.add_argument("--role", help="profile role override")
    ap.add_argument("--tier", choices=["T0", "T1", "T2", "T3"], help="prefer this tier or higher when reachable (falls back within the window)")
    ap.add_argument("--no-log", action="store_true", help="hide routing log lines")
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("chat", help="routed chat in the terminal (no tools); default for gem-mesh / -mobile")
    r = sub.add_parser("route", help="show the routing decision for a prompt without running it"); r.add_argument("prompt"); r.add_argument("--file", action="append", default=[])
    q = sub.add_parser("ask", help="one prompt, print the answer and the badge"); q.add_argument("prompt"); q.add_argument("--file", action="append", default=[])
    q.add_argument("--max-tokens", type=int)
    n = sub.add_parser("nodes", help="show reachable nodes"); n.add_argument("--wait", type=float, default=2.0)
    mm = sub.add_parser("memory", help="memory: status | sync | remember <fact> | recall <q> | facts | forget <n> | index <file> | serve")
    mm.add_argument("action", choices=["status", "sync", "remember", "recall", "facts", "forget", "index", "serve", "backfill"]); mm.add_argument("arg", nargs="*")
    sh = sub.add_parser("shim", help="Anthropic Messages-API shim for Claude Code"); sh.add_argument("--port", type=int, default=8790); sh.add_argument("--host", default="127.0.0.1")
    return ap


def _main(prog: str, default_role: str | None, argv=None) -> int:
    from meshcore import quiet_native_logs
    quiet_native_logs()
    ap = build_parser(prog)
    a = ap.parse_args(argv)
    role = a.role or default_role
    if a.cmd == "shim":
        from .shim import serve
        return serve(role=role, network=a.network, host=a.host, port=a.port)
    s = ClientSession.start(role=role, network=a.network, quiet=a.cmd in ("nodes",))
    s.prefer_tier = a.tier
    if a.cmd == "route":
        q, attached = attach_mentions(a.prompt)
        if attached:
            print(f"{DIM}attached {', '.join(attached)} ({len(q)//4:,} tokens){RESET}")
        return cmd_route(s, with_files(q, a.file))
    if a.cmd == "ask":
        q, attached = attach_mentions(a.prompt)
        if attached:
            print(f"{DIM}attached {', '.join(attached)} ({len(q)//4:,} tokens){RESET}")
        return cmd_ask(s, with_files(q, a.file), not a.no_log, a.max_tokens)
    if a.cmd == "nodes":
        s.table.wait(a.wait); print_header(s); s.close(); return 0
    if a.cmd == "memory":
        if a.action == "backfill":
            settle(s)
            rows = s.memory.db.execute("SELECT text FROM events WHERE kind='chat' AND role='user' ORDER BY rowid").fetchall()
            n = 0
            for (t,) in rows:
                for f in s.extract_facts(t):
                    print(f"remembered: {f}"); n += 1
            print(f"{n} fact(s) extracted from {len(rows)} message(s)"); s.close(); return 0
        if a.action == "serve":
            print(f"{s.memory_note} · Ctrl-C to stop", flush=True)
            import time as _t
            try:
                while True:
                    _t.sleep(3600)
            except KeyboardInterrupt:
                return 0
        mirror = s.memory and not s.memory.authority
        if a.action in ("sync", "status", "facts", "forget") and mirror:
            wait_for_phone(s)
            if a.action != "sync":
                s.sync_memory(quiet=True)      # what the chat's background sync does: the list and status are current
        memory_command(s, f"/{ {'status': 'memory'}.get(a.action, a.action) } " + " ".join(a.arg))
        if a.action == "forget" and mirror:
            s.sync_memory(quiet=True)          # the phone forgets it now, not at the next chat
        s.close(); return 0
    return run_chat(s, show_log=not a.no_log)



SUBCOMMANDS = {"chat", "route", "ask", "nodes", "shim", "memory"}
SHIM_PORT = 8790


def _shim_up(port: int) -> bool:
    import urllib.request
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as r:
            return r.status == 200
    except Exception:
        return False


def launch_claude_code(argv: list[str]) -> int:
    """Run the real Claude Code harness with every model call answered by the mesh through the shim."""
    import os, shutil, subprocess, sys, time
    from pathlib import Path
    port = int(os.environ.get("MESH_SHIM_PORT", SHIM_PORT))
    claude = shutil.which("claude")
    if not claude:
        print("gem-mesh code: Claude Code (`claude`) is not installed or not on PATH.", file=sys.stderr)
        return 127
    if not _shim_up(port) and sys.platform == "darwin":
        # installed as a login service by install.sh: ask launchd to (re)start it
        subprocess.run(["launchctl", "kickstart", f"gui/{os.getuid()}/com.gem-mesh.shim"], capture_output=True)
        for _ in range(30):
            if _shim_up(port):
                break
            time.sleep(0.5)
    if not _shim_up(port):
        from meshcore.profile import MESH_HOME
        log = MESH_HOME / "shim.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        exe = Path(sys.argv[0]).resolve()
        print(f"gem-mesh code: starting the mesh shim on :{port} (log {log})", file=sys.stderr, flush=True)
        subprocess.Popen([str(exe), "shim", "--port", str(port)], stdout=open(log, "a"), stderr=subprocess.STDOUT,
                         stdin=subprocess.DEVNULL, start_new_session=True)
        for _ in range(60):
            if _shim_up(port):
                break
            time.sleep(0.5)
        else:
            print(f"gem-mesh code: the shim did not come up; see {log}", file=sys.stderr)
            return 1
    model = os.environ.get("MESH_CLAUDE_MODEL", "gemma4-26b")
    env = dict(os.environ,
               ANTHROPIC_BASE_URL=f"http://127.0.0.1:{port}",
               ANTHROPIC_API_KEY=os.environ.get("MESH_ANTHROPIC_KEY", "mesh"),
               ANTHROPIC_MODEL=model, ANTHROPIC_SMALL_FAST_MODEL=model,
               CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1")
    os.execvpe(claude, [claude, *argv], env)

USAGE = """gem-mesh: your own devices as one private AI (Gemma 4 on LiteRT-LM)

  gem-mesh                  chat on this laptop (routes across your devices)
  gem-mesh ask "..."        one question, answer and badge
  gem-mesh route "..."      show where a question would go, without running it
  gem-mesh nodes            devices in your mesh right now
  gem-mesh memory status|sync|recall <q>|remember <fact>|facts|forget <n>
  gem-mesh node             run this machine's model server (installed as a login service)
  gem-mesh doctor           check profile, model, policy, discovery
  gem-mesh models list|pull <id>
  gem-mesh plan             which models fit this Mac (what the installer picks)
  gem-mesh profile show|init
  gem-mesh pair             connect a phone: address, checks, QR code; --secure requires pairing, --open undoes it
  gem-mesh join '<code>'    put a workstation or another Mac into a paired mesh
  gem-mesh role [workstation|laptop]   show this machine's role, or switch it
  gem-mesh model [12b|26b|31b|e4b|e2b] show this node's model, or switch it (downloads if needed)
  gem-mesh code [...]       optional: Claude Code on the mesh (needs install.sh --with-shim)

Inside a chat type /help. Demo files live in demo/files; name one in a message to attach it.
"""


def main(argv=None) -> int:
    """`gem-mesh`: one command for the laptop chat, the phone stand-in, the node server and the operator tools."""
    import sys
    args = list(sys.argv[1:] if argv is None else argv)
    if args and args[0] in ("-h", "--help", "help"):
        print(USAGE); return 0
    first = args[0] if args else None
    rest = args[1:]
    if first == "phone":
        return _main("gem-mesh-mobile", "mobile-mock", rest)
    if first == "node":
        from meshnode.app import main as node_main
        return node_main(rest)
    if first in ("doctor", "models", "profile", "plan"):
        from meshcore.cli import main as ops_main
        lead = []
        if "--role" in rest:
            i = rest.index("--role"); lead = rest[i:i + 2]; rest = rest[:i] + rest[i + 2:]
        return ops_main(lead + [first] + rest)
    if first == "code":
        return launch_claude_code(rest)
    if first == "pair":
        return cmd_pair(rest)
    if first == "join":
        return cmd_join(rest)
    if first == "role":
        return cmd_role(rest)
    if first == "model":
        return cmd_model(rest)
    return _main("gem-mesh", None, args)


def _restart_node(role: str = "macbook") -> str:
    """Restart this machine's node service so it picks up a pairing change."""
    import os, subprocess, sys
    if sys.platform == "darwin":
        r = subprocess.run(["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/com.gem-mesh.node"], capture_output=True)
        return "node restarted" if r.returncode == 0 else "restart the node yourself: gem-mesh node (no login service found)"
    r = subprocess.run(["systemctl", "--user", "restart", "gem-mesh-node.service"], capture_output=True)
    return "node restarted" if r.returncode == 0 else "restart the node yourself: gem-mesh node"


def cmd_pair(argv: list[str]) -> int:
    """Pairing is optional. Open: anyone on the network can use this Mac (your risk). --secure: HTTPS + mesh key."""
    import argparse, json, subprocess, time, urllib.request, ssl
    from meshcore import security
    from meshcore.discovery import _own_ips
    from meshcore.profile import load_profile
    ap = argparse.ArgumentParser(prog="gem-mesh pair")
    ap.add_argument("--secure", action="store_true", help="require pairing: HTTPS and the mesh key from now on")
    ap.add_argument("--open", action="store_true", help="stop requiring pairing (back to open, at your own risk)")
    ap.add_argument("--yes", action="store_true", help="do not ask before changing")
    a = ap.parse_args(argv)
    prof = load_profile(role="macbook")
    ips = _own_ips()
    ip = ips[0] if ips else None
    port = prof.node_port
    mesh = security.load()

    def confirm(q: str) -> bool:
        if a.yes or not sys.stdin.isatty():
            return a.yes
        return input(f"{q} [y/N] ").strip().lower() in ("y", "yes")

    if a.open:
        if not mesh:
            print("This mesh is already open."); return 0
        if not confirm("Stop requiring pairing? Anyone on your network will be able to use this Mac and read the phone's memory."):
            print("unchanged"); return 1
        moved = security.leave()
        print(f"{AMBER}open{RESET}: pairing secrets moved to {moved}. {_restart_node()}. Paired devices must forget this Mac.")
        return 0
    if a.secure and not mesh:
        print("Pairing makes this mesh private: HTTPS between devices, and only devices with the mesh key can use this Mac\n"
              "or the phone's memory. Devices that are not paired (including an app without pairing support) lose access.")
        if not confirm("Create the mesh key now?"):
            print("unchanged"); return 1
        mesh = security.create(prof.device, prof.mesh, sans=ips)
        print(f"{GREEN}paired mesh created{RESET} in {mesh.dir}. {_restart_node()}.")
        time.sleep(3)

    scheme = "https" if mesh else "http"
    node = f"{scheme}://{ip}:{port}" if ip else None
    print(f"{BOLD}Pair a phone with this Mac{RESET}\n")
    print(f"device   {prof.device} · {prof.tier} · {prof.model}")
    print(f"mesh     {prof.mesh}   (the app must use the same mesh name)")
    print(f"address  {node or 'no LAN address: connect to Wi-Fi or the phone hotspot'}")
    if mesh:
        print(f"security {GREEN}paired{RESET}: HTTPS, mesh key required · authority {mesh.ca_fingerprint()[:16]}…")
    else:
        print(f"security {AMBER}open{RESET}: plain HTTP; anyone on this network can use this Mac and read the phone's memory "
              f"(your risk). Make it private: gem-mesh pair --secure")

    ctx = mesh.client_ssl() if mesh else None
    hdr = {"Authorization": f"Bearer {mesh.key}"} if mesh else {}

    def get(url):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=4, context=ctx) as r:
                return json.loads(r.read())
        except Exception as e:
            return {"error": type(e).__name__}
    info = get(f"{scheme}://127.0.0.1:{port}/mesh/info")
    ok = "error" not in info
    print(f"\n{(GREEN if ok else AMBER)}{'ok  ' if ok else 'xx  '}{RESET} node running on :{port}" +
          (f" ({info.get('model')}, window {info.get('max_num_tokens'):,} tokens)" if ok else
           "  → start it: gem-mesh node (or re-run ./install.sh); after --secure give it a few seconds"))
    if node:
        lan = get(f"{node}/health")
        ok2 = lan.get("status") == "ok"
        print(f"{(GREEN if ok2 else AMBER)}{'ok  ' if ok2 else 'xx  '}{RESET} answers on its LAN address {node}")
    fw = subprocess.run(["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate"], capture_output=True, text=True).stdout
    if "enabled" in fw.lower():
        print(f"{AMBER}!!  {RESET} macOS firewall is on: if the phone cannot connect, allow incoming connections for Python "
              "(System Settings → Network → Firewall → Options), or turn off 'Block all incoming connections'")
    else:
        print(f"{GREEN}ok  {RESET} macOS firewall off (or allows incoming)")
    code = security.pairing_code(mesh, prof.device, prof.mesh, node)
    payload = json.dumps(code, separators=(",", ":"))
    if mesh:
        print(f"\nOn the phone: Settings → Your Mac → Scan QR code. The code holds the mesh key: show it only to your own devices.")
        print(f"Another Mac or a workstation joins with:  gem-mesh join '{payload}'")
    else:
        print(f"\nOn the phone: open {node}/mesh/info in Chrome. JSON with \"model\" means the phone can reach this Mac.")
        print("Same Wi-Fi, or the Mac on the phone's hotspot. Guest and many office networks block device-to-device traffic.")
    print("Android emulator: the Mac is %s://10.0.2.2:%d (no mDNS inside the emulator)." % (scheme, port))
    print(f"\nPairing code for the app (scan, or paste):\n{payload}\n")
    try:
        import qrcode
        q = qrcode.QRCode(border=1)
        q.add_data(payload)
        q.print_ascii(invert=True)
    except Exception:
        print("(install qrcode to show it as a QR code: uv sync)")
    return 0


def current_role() -> str:
    """The role this machine's node service runs as: workstation or laptop (macbook)."""
    import subprocess, sys
    from pathlib import Path
    if sys.platform == "darwin":
        pl = Path.home() / "Library/LaunchAgents/com.gem-mesh.node.plist"
        text = pl.read_text() if pl.exists() else ""
    else:
        u = Path.home() / ".config/systemd/user/gem-mesh-node.service"
        text = u.read_text() if u.exists() else ""
    if not text:
        return "none"
    for r in ("workstation", "server"):
        if f"<string>{r}</string>" in text or f"--role {r}" in text:
            return r
    return "laptop"


def cmd_role(argv: list[str]) -> int:
    """`gem-mesh role` shows this machine's role; `gem-mesh role workstation|laptop` switches it (re-runs the installer)."""
    import os, subprocess
    from pathlib import Path
    names = {"laptop": "macbook", "macbook": "macbook", "workstation": "workstation"}
    now = current_role()
    if not argv:
        what = {"workstation": "workstation (T2): a bigger node for the other devices",
                "laptop": "laptop (T1): this Mac's own node plus the chat", "none": "no node service installed (run ./install.sh)"}
        print(f"role     {what.get(now, now)}")
        print("switch   gem-mesh role workstation   ·   gem-mesh role laptop")
        return 0
    want = argv[0].lower()
    if want not in names:
        print("usage: gem-mesh role [workstation|laptop]"); return 2
    if now == ("laptop" if names[want] == "macbook" else want):
        print(f"already a {want}. Re-running the installer anyway refreshes the model choice and the service.")
    repo = Path(__file__).resolve().parents[3]
    installer = repo / "scripts" / "install.sh"
    if not installer.exists():
        print(f"installer not found at {installer}"); return 1
    args = [str(installer), "--role", names[want]] + [a for a in argv[1:]]
    print(f"switching this machine to {want}: {' '.join(args[1:])}", flush=True)
    return subprocess.call(args, cwd=str(repo))


MODEL_ALIASES = {"e2b": "gemma4-e2b", "e4b": "gemma4-e4b", "12b": "gemma4-12b-gpu", "26b": "gemma4-26b", "31b": "gemma4-31b",
                 "small": "gemma4-e2b", "medium": "gemma4-e4b", "large": "gemma4-12b-gpu", "xl": "gemma4-26b"}


def cmd_model(argv: list[str]) -> int:
    """`gem-mesh model` shows this node's model; `gem-mesh model 12b|26b|31b|e4b|e2b|<id>` switches it."""
    import time, urllib.request
    from meshcore.cli import gpu_gb, ram_gb, _curl_download
    from meshcore.policy import load_policy
    from meshcore.profile import load_profile, profile_path_for, write_profile
    role = {"laptop": "macbook", "none": "macbook"}.get(current_role(), current_role())
    prof = load_profile(profile_path_for(role))
    pol = load_policy(prof.policy_path())
    mem = gpu_gb() if role in ("workstation", "server") else ram_gb()
    fits = pol.sizing_for_role(role, mem)["model"]
    if not argv:
        print(f"model    {prof.model} · context {prof.max_num_tokens:,} · {prof.max_sessions} conversation(s) · role {current_role()}")
        print(f"fits     {fits} (picked for {mem:.0f} GB{' of GPU memory' if role != 'macbook' else ''})")
        for mid, spec in pol.models.items():
            if mid.startswith("embedding"):
                continue
            have = prof.model_path(mid).exists() and prof.model_path(mid).stat().st_size == spec.bytes
            short = next((k for k, v in MODEL_ALIASES.items() if v == mid and k[0].isdigit() or v == mid and k[0] == "e"), mid)
            mark = "← running" if mid == prof.model else ""
            print(f"  {short:<5} {mid:<16} {spec.bytes / 1e9:5.1f} GB  {'downloaded' if have else 'not downloaded':<14} {mark}")
        print("switch   gem-mesh model 12b   (downloads it if needed, then restarts the node)")
        return 0
    want = MODEL_ALIASES.get(argv[0].lower(), argv[0])
    spec = pol.models.get(want)
    if not spec or want.startswith("embedding"):
        print(f"unknown model {argv[0]}; choose one of: " + ", ".join(sorted(k for k in MODEL_ALIASES if k[0].isdigit() or k[0] == 'e'))); return 2
    if want == prof.model:
        print(f"already running {want}"); return 0
    if mem and spec.bytes / 1e9 > mem * 0.9:
        print(f"{AMBER}warning{RESET}: {want} is {spec.bytes / 1e9:.1f} GB and this machine has about {mem:.0f} GB for models; it may not load.")
    if not prof.model_path(want).exists() or prof.model_path(want).stat().st_size != spec.bytes:
        print(f"downloading {want} ({spec.bytes / 1e9:.1f} GB)…", flush=True)
        if not _curl_download(spec.url, prof.model_path(want), spec.bytes):
            print("download did not finish; run the same command again to resume"); return 1
    size = pol.sizing_for_role(role, mem, want)
    prof.model = want
    if size.get("context"):
        prof.max_num_tokens = int(size["context"])
    if size.get("sessions"):
        prof.max_sessions = int(size["sessions"])
    write_profile(prof, prof.path)
    print(f"profile  {want} · context {prof.max_num_tokens:,} · {prof.max_sessions} conversation(s) → {prof.path}")
    print(_restart_node(role), flush=True)
    for _ in range(120):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{prof.node_port}/health", timeout=2):
                pass
            break
        except Exception:
            time.sleep(1)
    back = next((k for k, v in MODEL_ALIASES.items() if v == fits and (k[0].isdigit() or k[0] == 'e')), fits)
    print(f"{GREEN}ok{RESET}  the node now serves {want}." + ("" if want == fits else f" The size picked for this machine: gem-mesh model {back}"))
    return 0


def cmd_join(argv: list[str]) -> int:
    """Put this machine (a workstation, another Mac) into a paired mesh, from the code `gem-mesh pair` prints."""
    import json
    from meshcore import security
    from meshcore.profile import load_profile
    if not argv:
        print("usage: gem-mesh join '<pairing code JSON from gem-mesh pair on the paired Mac>' [--role workstation]"); return 2
    from meshcore.profile import profile_path_for
    role = argv[argv.index("--role") + 1] if "--role" in argv else (
        "workstation" if profile_path_for("workstation").exists() else "macbook")
    try:
        code = json.loads(argv[0])
    except ValueError:
        print("that is not a pairing code (it is the JSON line gem-mesh pair prints)"); return 2
    prof = load_profile(role=role)
    try:
        mesh = security.join(code, prof.device, role)
    except Exception as e:
        print(f"{AMBER}not joined{RESET}: {e}"); return 1
    print(f"{GREEN}joined{RESET} the paired mesh {code.get('mesh')} (authority {mesh.ca_fingerprint()[:16]}…). {_restart_node(role)}.")
    return 0


def main_mobile(argv=None) -> int:
    """`gem-mesh-mobile`: developer tool, the phone stand-in (same as `gem-mesh phone`). Linked onto PATH only by
    `./install.sh --dev`; not part of the user-facing help."""
    import sys
    return main(["phone", *(sys.argv[1:] if argv is None else argv)])
