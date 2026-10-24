"""`mesh` command: nodes, doctor, models, profile. Small operator tools shared by every role."""
from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

from .discovery import NodeTable
from .network import detect
from .policy import load_policy
from .profile import MESH_HOME, Profile, ROLE_DEFAULTS, load_profile, profile_path_for, write_profile


def ram_gb() -> float | None:
    if os.environ.get("MESH_RAM_GB"):          # test what the installer would pick on a smaller Mac
        return float(os.environ["MESH_RAM_GB"])
    try:
        if platform.system() == "Darwin":
            return int(subprocess.check_output(["sysctl", "-n", "hw.memsize"]).strip()) / 2**30
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal"):
                    return int(line.split()[1]) / 2**20
    except Exception:
        return None
    return None


def gpu_gb() -> float | None:
    """Memory a node's model can use: the largest NVIDIA card's VRAM on Linux (one node runs on one GPU),
    otherwise the machine's memory (Apple silicon shares it with the GPU)."""
    if os.environ.get("MESH_GPU_GB"):          # test: the GPU memory to assume
        return float(os.environ["MESH_GPU_GB"])
    if platform.system() == "Linux" and shutil.which("nvidia-smi"):
        try:
            out = subprocess.check_output(["nvidia-smi", "--query-gpu=memory.total", "--format=csv,noheader,nounits"], text=True)
            sizes = [float(x) / 1024 for x in out.split() if x.strip()]
            if sizes:
                return max(sizes)
        except Exception:
            pass
    ram = ram_gb()
    if ram and platform.system() == "Darwin":
        return ram * 2 / 3            # macOS lets the GPU wire about two thirds of unified memory by default
    return ram


def cmd_nodes(a) -> int:
    prof = load_profile(role=a.role)
    table = NodeTable(mesh=prof.mesh, static_urls=prof.static_nodes).start()
    table.wait(a.wait)
    nodes = table.nodes()
    net = detect(a.network, prof.hotspot_ssids, prof.office_ssids)
    print(f"net    {net.describe()} ({net.detail})")
    if not nodes:
        print("mesh   no nodes found")
    for n in sorted(nodes, key=lambda n: n.tier):
        lat = f"{n.latency_ms:.0f} ms" if n.latency_ms is not None else "unreachable"
        print(f"mesh   {n.device:<14} {n.tier:<3} {n.model:<16} load {n.load:.2f}  {lat}  {n.base_url or 'in-process'}  [{n.source}]")
    table.stop()
    return 0


def cmd_doctor(a) -> int:
    ok = True
    prof = load_profile(role=a.role)
    print(f"profile    {prof.path} role={prof.role} tier={prof.tier} model={prof.model} device={prof.device}")
    pol = load_policy(prof.policy_path())
    print(f"policy     {pol.dir}  rules={len(pol.rules)} terms={len(pol.terms)} models={len(pol.models)}")
    for w in pol.warnings:
        print(f"  warning  {w}"); ok = False
    mp = prof.model_path()
    spec = pol.models.get(prof.model)
    if mp.exists():
        size = mp.stat().st_size
        good = (spec is None) or (size == spec.bytes)
        print(f"model      {mp} {size/1e9:.1f} GB {'ok' if good else 'SIZE MISMATCH, expected ' + str(spec.bytes)}")
        ok &= good
    else:
        print(f"model      MISSING {mp}  → mesh models pull {prof.model}"); ok = False
    try:
        import litert_lm  # noqa: F401
        print("litert-lm  importable")
    except Exception as e:
        print(f"litert-lm  NOT importable: {e}"); ok = False
    net = detect(None, prof.hotspot_ssids, prof.office_ssids)
    print(f"network    {net.describe()} gateway={net.gateway}")
    table = NodeTable(mesh=prof.mesh, static_urls=prof.static_nodes).start(); table.wait(2.0)
    nodes = table.nodes(); table.stop()
    print(f"discovery  {len(nodes)} node(s): " + ", ".join(f"{n.device}/{n.tier}/{n.model}" for n in nodes))
    if prof.advertise:
        import httpx
        try:
            r = httpx.get(f"http://127.0.0.1:{prof.node_port}/mesh/info", timeout=3)
            d = r.json(); print(f"meshnode   up on :{prof.node_port} serving {d.get('model')} ({d.get('sessions')} sessions)")
        except Exception:
            print(f"meshnode   not responding on :{prof.node_port}  → start it: meshnode" + (f" --role {prof.role}" if prof.role != 'macbook' else ''))
            ok = False
    print("result     " + ("ok" if ok else "problems found"))
    return 0 if ok else 1


def _curl_download(url: str, dest: Path, expected: int | None) -> bool:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and expected and dest.stat().st_size == expected:
        print(f"already complete: {dest}"); return True
    cmd = ["curl", "-fL", "-C", "-", "--retry", "5", "--progress-bar", "-o", str(dest), url]
    print(" ".join(cmd))
    rc = subprocess.call(cmd)
    if rc != 0:
        print(f"download failed (curl exit {rc}); rerun to resume"); return False
    size = dest.stat().st_size
    if expected and size != expected:
        print(f"size mismatch: {size} != {expected}; rerun to resume"); return False
    print(f"ok {dest} {size/1e9:.1f} GB"); return True


def cmd_models(a) -> int:
    prof = load_profile(role=a.role)
    pol = load_policy(prof.policy_path())
    if a.models_cmd == "list":
        for mid, spec in pol.models.items():
            p = prof.model_path(mid); have = p.exists() and p.stat().st_size == spec.bytes
            print(f"{mid:<16} {spec.bytes/1e9:5.1f} GB  {'present' if have else ('partial' if p.exists() else 'absent'):<8} {spec.file}")
        return 0
    if a.models_cmd == "pull":
        mid = a.model or prof.model
        spec = pol.models.get(mid)
        if not spec:
            print(f"unknown model id {mid}; see mesh models list"); return 2
        return 0 if _curl_download(spec.url, prof.model_path(mid), spec.bytes) else 1
    return 2


def cmd_plan(a) -> int:
    """Print the sizing for this Mac (laptop + phone stand-in + vision) as shell-friendly lines for install.sh."""
    pol = load_policy(load_profile(role="macbook").policy_path())
    ram = ram_gb() or 0
    lap = pol.sizing_for_role("macbook", ram, a.model)
    ph = pol.sizing_for_role("mobile-mock", ram)
    vis = lap.get("vision") or ph["model"]
    need = {lap["model"], ph["model"], vis, "embeddinggemma-2"}
    total = sum(pol.models[m].bytes for m in need if m in pol.models)
    print(f"RAM_GB={ram:.0f}\nLAPTOP_MODEL={lap['model']}\nPHONE_MODEL={ph['model']}\nVISION_MODEL={vis}\n"
          f"CONTEXT={lap.get('context', '')}\nDOWNLOAD_GB={total / 1e9:.1f}\nMODELS=\"{' '.join(sorted(need))}\"")
    return 0


def cmd_profile(a) -> int:
    if a.profile_cmd == "show":
        prof = load_profile(role=a.role); print(prof.to_yaml().rstrip()); print(f"# {prof.path}"); return 0
    if a.profile_cmd == "init":
        role = a.role or "macbook"
        pol_dir = Path(a.policy_dir).expanduser() if a.policy_dir else None
        prof = Profile(role=role, **ROLE_DEFAULTS.get(role, {}))
        target = Path(a.path).expanduser() if a.path else profile_path_for(role)
        prev = load_profile(target) if target.exists() else None
        if a.device:
            prof.device = a.device
        elif prev is not None and prev.device:
            prof.device = prev.device                   # re-running the installer keeps this machine's identity
        elif role == "mobile-mock":
            prof.device = f"{prof.device.lower()}-phone"  # never the laptop's name: each device has its own memory file
        else:
            # A machine switching role (gem-mesh role workstation|laptop) keeps its name: reuse any existing profile's.
            for other in ("macbook", "workstation", "server"):
                op = profile_path_for(other)
                if other != role and op.exists():
                    prof.device = load_profile(op).device
                    break
        if prev is not None:
            prof.static_nodes = prev.static_nodes; prof.hotspot_ssids = prev.hotspot_ssids; prof.office_ssids = prev.office_ssids
        if pol_dir: prof.policy_dir = str(pol_dir)
        pol = load_policy(prof.policy_path())
        size = pol.sizing_for_role(role, gpu_gb() if role in ("workstation", "server") else ram_gb(), a.model)
        prof.model = size["model"]
        if size.get("context"):
            prof.max_num_tokens = int(size["context"])
        if size.get("sessions"):
            prof.max_sessions = int(size["sessions"])
        if size.get("vision"):
            prof.vision_model = size["vision"]
        if a.static_node: prof.static_nodes = list(a.static_node)
        p = write_profile(prof, profile_path_for(role) if not a.path else a.path)
        print(f"wrote {p}\n{prof.to_yaml()}"); return 0
    return 2


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="mesh", description="Gem Mesh operator tools")
    ap.add_argument("--role", help="profile to use (macbook default, or mobile-mock, workstation, server)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("nodes", help="show reachable nodes"); s.add_argument("--wait", type=float, default=2.0); s.add_argument("--network")
    sub.add_parser("doctor", help="check profile, policy, model, discovery, node")
    pl = sub.add_parser("plan", help="what install.sh would choose on this machine"); pl.add_argument("--model")
    m = sub.add_parser("models", help="model catalog"); ms = m.add_subparsers(dest="models_cmd", required=True)
    ms.add_parser("list"); mp = ms.add_parser("pull"); mp.add_argument("model", nargs="?")
    p = sub.add_parser("profile", help="device profile"); ps = p.add_subparsers(dest="profile_cmd", required=True)
    ps.add_parser("show"); pi = ps.add_parser("init")
    pi.add_argument("--device"); pi.add_argument("--model"); pi.add_argument("--policy-dir"); pi.add_argument("--path")
    pi.add_argument("--static-node", action="append")
    a = ap.parse_args(argv)
    return {"nodes": cmd_nodes, "doctor": cmd_doctor, "models": cmd_models, "profile": cmd_profile, "plan": cmd_plan}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
