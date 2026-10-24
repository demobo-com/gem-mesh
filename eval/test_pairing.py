"""End-to-end check of pairing (needs gemma4-e2b downloaded). Isolated: scratch homes, port 9431, mesh "pairtest".

    uv run python eval/test_pairing.py
"""
import json
import os
import ssl
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "core"), str(ROOT / "clients/cli")]
import httpx  # noqa: E402

from meshcore import security  # noqa: E402

PORT, MESH = 9431, "pairtest"
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"{'ok ' if ok else 'XX '} {name}" + (f"   ({detail})" if detail and not ok else ""))


def profile(home: Path, device: str, port: int, model="gemma4-e2b"):
    home.mkdir(parents=True, exist_ok=True)
    (home / "profile.yaml").write_text(
        f"role: macbook\ndevice: {device}\ntier: T1\nmodel: {model}\nmax_num_tokens: 4096\nmax_sessions: 1\nmemory: none\n"
        f"mesh: {MESH}\nnode_port: {port}\nadvertise: true\nmodels_dir: {Path.home() / '.litert-lm/models'}\n")


tmp = Path(tempfile.mkdtemp(prefix="gm-pair-"))
mac, other = tmp / "mac", tmp / "other"
profile(mac, "pair-mac", PORT)
profile(other, "pair-ws", PORT + 1)
m = security.create("pair-mac", MESH, sans=["127.0.0.1"], home=mac)
env = dict(os.environ, MESH_HOME=str(mac))
node = subprocess.Popen([str(ROOT / ".venv/bin/gem-mesh"), "node"], env=env, stdout=open(tmp / "node.log", "w"), stderr=subprocess.STDOUT)
try:
    base = f"https://127.0.0.1:{PORT}"
    for _ in range(90):
        try:
            if httpx.get(f"{base}/health", verify=m.client_ssl(), timeout=1).status_code == 200:
                break
        except Exception:
            time.sleep(1)
    key = {"Authorization": f"Bearer {m.key}"}

    try:
        r = httpx.get(f"http://127.0.0.1:{PORT}/mesh/info", timeout=3); plain = r.status_code
    except Exception as e:
        plain = type(e).__name__
    check("plain HTTP is refused", plain != 200, plain)
    check("/health is open over HTTPS", httpx.get(f"{base}/health", verify=m.client_ssl()).status_code == 200)
    check("/mesh/info without the key → 401", httpx.get(f"{base}/mesh/info", verify=m.client_ssl()).status_code == 401)
    check("wrong key → 401", httpx.get(f"{base}/mesh/info", verify=m.client_ssl(), headers={"Authorization": "Bearer nope"}).status_code == 401)
    try:
        httpx.get(f"{base}/mesh/info", headers=key, timeout=3); sys_trust = "accepted"
    except Exception as e:
        sys_trust = type(e).__name__
    check("the node's certificate is not trusted outside the mesh", sys_trust != "accepted", sys_trust)
    other_ca = security.create("x", "x", home=tmp / "stranger")
    try:
        httpx.get(f"{base}/mesh/info", headers=key, verify=other_ca.client_ssl(), timeout=3); cross = "accepted"
    except Exception as e:
        cross = type(e).__name__
    check("another mesh's authority does not trust it", cross != "accepted", cross)
    info = httpx.get(f"{base}/mesh/info", verify=m.client_ssl(), headers=key).json()
    check("with the key and the mesh authority → /mesh/info", info.get("device") == "pair-mac", str(info)[:80])
    chat = httpx.post(f"{base}/v1/chat/completions", verify=m.client_ssl(), headers=key, timeout=120,
                      json={"messages": [{"role": "user", "content": "Say OK"}], "max_tokens": 5}).json()
    check("chat over the paired connection", bool(chat.get("choices")), str(chat)[:80])

    code = security.pairing_code(m, "pair-mac", MESH, base)
    check("pairing code carries key and authority fingerprint", code["v"] == 2 and code["key"] == m.key and len(code["ca"]) == 64)
    bad = dict(code, ca="0" * 64)
    try:
        security.join(bad, "evil", "macbook", home=tmp / "evil"); refused = False
    except ValueError:
        refused = True
    check("join refuses a code whose authority does not match", refused)
    w = security.join(code, "pair-ws", "workstation", home=other)
    check("join: a second machine enrolls and gets its own certificate", w.cert_pem.exists() and w.key == m.key)
    r = httpx.get(f"{base}/mesh/info", **w.httpx_kwargs())
    check("the joined machine reaches the node", r.status_code == 200)

    # discovery: paired sees it over https; open and other meshes do not; a fake open node is ignored
    from meshcore.discovery import Advertiser, NodeTable
    fake = Advertiser("fake-t3", "T3", "gemma4-31b", PORT + 5, MESH)            # announces the same mesh, no TLS
    fake.start()
    time.sleep(3)
    paired = NodeTable(mesh=MESH, security=w).start()
    opened = NodeTable(mesh=MESH, security=None).start()
    time.sleep(6)
    pk = list(paired._remote.keys()); ok_ = list(opened._remote.keys())
    check("paired client finds the node over HTTPS", any(u.startswith("https://") and str(PORT) in u for u in pk), str(pk))
    check("paired client ignores a fake open node on the same mesh name", not any(str(PORT + 5) in u for u in pk), str(pk))
    check("open client skips the paired node", not any(str(PORT) in u and str(PORT + 5) not in u for u in ok_), str(ok_))
    paired.stop(); opened.stop(); fake.stop()

    # memory: a paired phone's memory server needs the key
    from meshcore.memory import MemoryStore
    from meshcore.memory_server import serve_in_background
    phone = MemoryStore(tmp / "phone.db", "pair-phone", authority=True, embedder=None)
    phone.append("fact", "Mia lives in Lisbon.")
    serve_in_background(phone, "127.0.0.1", PORT + 2, mesh=w)
    time.sleep(2)
    mirror = MemoryStore(tmp / "mirror.db", "pair-mac", authority=False, embedder=None)
    res = mirror.sync_with(f"https://127.0.0.1:{PORT + 2}", client_kwargs=m.httpx_kwargs())
    check("memory sync with the key", res["pulled"] == 1, str(res))
    st = httpx.get(f"https://127.0.0.1:{PORT + 2}/memory/pull", verify=m.client_ssl()).status_code
    check("memory pull without the key → 401", st == 401, st)
finally:
    node.terminate()
    try:
        node.wait(10)
    except subprocess.TimeoutExpired:
        node.kill()
print(f"\n{sum(results)}/{len(results)} pairing checks pass")
sys.exit(0 if all(results) else 1)
