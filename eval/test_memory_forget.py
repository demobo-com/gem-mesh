"""Forgetting syncs both ways: no models needed. An authority (the phone) served over HTTP and a mirror (the Mac).
Run: uv run python eval/test_memory_forget.py"""
import socket
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "core"))
from meshcore.memory import MemoryStore  # noqa: E402
from meshcore.memory_server import serve_in_background  # noqa: E402

tmp = Path(tempfile.mkdtemp())
phone = MemoryStore(tmp / "phone.db", "phone", authority=True, embedder=None)
mac = MemoryStore(tmp / "mac.db", "mac", authority=False, embedder=None)
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
serve_in_background(phone, "127.0.0.1", port)
url = f"http://127.0.0.1:{port}"
for _ in range(50):
    try:
        mac.sync_with(url)
        break
    except Exception:
        time.sleep(0.1)

fails = 0


def check(name, ok, got=""):
    global fails
    fails += not ok
    print(f"{'ok  ' if ok else 'FAIL'} {name}" + ("" if ok else f"  got: {got}"))


def texts(store):
    return sorted(f["text"] for f in store.facts())


# A fact written on the phone reaches the Mac; forgetting it on the phone removes it there too.
mia = phone.append("fact", "The user's sister Mia lives in Lisbon.")
mac.sync_with(url)
check("phone fact reaches the Mac", texts(mac) == ["The user's sister Mia lives in Lisbon."], texts(mac))
phone.forget([mia], "forgot: Mia")
check("phone forgets at once", texts(phone) == [], texts(phone))
mac.sync_with(url)
check("the Mac forgets it at the next sync", texts(mac) == [], texts(mac))

# A fact written on the Mac reaches the phone; forgetting it on the Mac removes it on the phone.
bob = mac.append("fact", "The user's dentist is Dr. Bob.")
mac.sync_with(url)
check("Mac fact reaches the phone", texts(phone) == ["The user's dentist is Dr. Bob."], texts(phone))
mac.forget([bob], "forgot: dentist")
check("Mac forgets at once", texts(mac) == [], texts(mac))
mac.sync_with(url)
check("the phone forgets it at the next sync", texts(phone) == [], texts(phone))

# A forgotten event that arrives again (an old copy, a device that missed the forget) is not taken back.
old = {"id": mia, "device": "phone", "seq": 1, "ts": time.time(), "kind": "fact", "session": None, "role": None,
       "text": "The user's sister Mia lives in Lisbon.", "meta": {}}
check("an old copy is refused on the phone", phone.ingest([old]) == 0 and texts(phone) == [], texts(phone))
check("an old copy is refused on the Mac", mac.ingest([old]) == 0 and texts(mac) == [], texts(mac))

# Forgetting something never pushed: only the forget goes out, and nothing else is touched.
keep = phone.append("fact", "The user prefers tea.")
tmp_fact = mac.append("fact", "A typo the user corrected.")
mac.forget([tmp_fact])
mac.sync_with(url)
check("an unpushed fact never reaches the phone", texts(phone) == ["The user prefers tea."], texts(phone))
check("other facts are untouched", texts(mac) == ["The user prefers tea."], texts(mac))
check("forget events are kept and synced", phone.stats()["by_kind"].get("forget") == 3, phone.stats()["by_kind"])
first_forget = phone.db.execute("SELECT id FROM events WHERE kind = 'forget' ORDER BY rowid LIMIT 1").fetchone()[0]
phone.forget([first_forget])
still = phone.db.execute("SELECT COUNT(*) FROM events WHERE id = ?", (first_forget,)).fetchone()[0]
check("a forget event cannot itself be forgotten", still == 1 and texts(phone) == ["The user prefers tea."], (still, texts(phone)))

print(f"\n{'all pass' if not fails else f'{fails} failed'}")
sys.exit(1 if fails else 0)
