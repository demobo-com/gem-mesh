"""Device profile: who this machine is in the mesh and what it serves.

Written by install.sh to ~/.gem-mesh/profile.yaml (or profile-<role>.yaml for a
second identity on the same machine, such as the mock mobile). Precedence at runtime:
explicit overrides > profile file > defaults.
"""
from __future__ import annotations

import os
import socket
from dataclasses import dataclass, field, asdict
from pathlib import Path

import yaml

def _home() -> Path:
    """~/.gem-mesh. Installs from before a rename keep their folder (~/.gemma-mesh, ~/.local-ai-mesh): profiles,
    memory and logs stay where they are."""
    if os.environ.get("MESH_HOME"):
        return Path(os.environ["MESH_HOME"]).expanduser()
    new = Path.home() / ".gem-mesh"
    if new.exists():
        return new
    for old in (Path.home() / ".gemma-mesh", Path.home() / ".local-ai-mesh"):
        if old.exists():
            return old
    return new


MESH_HOME = _home()


def _repo_policy_dir() -> Path | None:
    """The repo's policy/ folder when running from a checkout, else None."""
    here = Path(__file__).resolve()
    for parent in here.parents:
        cand = parent / "policy"
        if (cand / "tiers.yaml").exists():
            return cand
    return None


@dataclass
class Profile:
    role: str = "macbook"                 # macbook | workstation | server | mobile-mock
    device: str = field(default_factory=lambda: socket.gethostname().split(".")[0])
    tier: str = "T1"
    model: str = "gemma4-26b"
    max_num_tokens: int = 32768
    max_sessions: int = 2                 # resident conversations, each with its own KV cache
    cache: str = "no"
    memory: str = "mirror"                # authority | mirror | none
    memory_peer: str | None = None        # mirror: pin the phone's memory endpoint, e.g. http://<phone>:9401 (default: found over mDNS)
    mesh: str = "default"
    node_host: str = "0.0.0.0"
    node_port: int = 9400
    advertise: bool = True                # the phone / mobile-mock never advertises
    policy_dir: str | None = None
    static_nodes: list[str] = field(default_factory=list)   # http://host:port, for VPN or when mDNS cannot cross
    hotspot_ssids: list[str] = field(default_factory=list)
    office_ssids: list[str] = field(default_factory=list)
    models_dir: str = str(Path.home() / ".litert-lm" / "models")
    vision_model: str | None = None       # small on-device model the chat uses to look at images (E2B/E4B)
    path: str | None = None               # where this profile was loaded from

    def policy_path(self) -> Path:
        if self.policy_dir:
            return Path(self.policy_dir).expanduser()
        repo = _repo_policy_dir()
        if repo:
            return repo
        return MESH_HOME / "policy"

    def model_path(self, model_id: str | None = None) -> Path:
        return Path(self.models_dir).expanduser() / (model_id or self.model) / "model.litertlm"

    def memory_path(self) -> Path:
        return MESH_HOME / f"memory-{self.device}.db"

    def is_local_only(self) -> bool:
        return self.role == "mobile-mock"

    def to_yaml(self) -> str:
        d = asdict(self)
        d.pop("path", None)
        return yaml.safe_dump(d, sort_keys=False)


ROLE_DEFAULTS = {
    "macbook":     dict(tier="T1", model="gemma4-26b", memory="mirror", advertise=True),   # finds the phone's memory over mDNS
    "workstation": dict(tier="T2", model="gemma4-26b", memory="none", advertise=True, max_num_tokens=32768, max_sessions=2),
    "server":      dict(tier="T3", model="gemma4-31b", memory="none", advertise=True, max_num_tokens=16384, max_sessions=1),
    "mobile-mock": dict(tier="T0", model="gemma4-e4b", memory="authority", advertise=False, node_port=9401),
}


def profile_path_for(role: str | None = None) -> Path:
    env = os.environ.get("MESH_PROFILE")
    if env:
        return Path(env).expanduser()
    if role and role != "macbook":
        return MESH_HOME / f"profile-{role}.yaml"
    return MESH_HOME / "profile.yaml"


def load_profile(path: str | Path | None = None, role: str | None = None, **overrides) -> Profile:
    p = Path(path).expanduser() if path else profile_path_for(role)
    data: dict = {}
    if p.exists():
        data = yaml.safe_load(p.read_text()) or {}
    merged = dict(ROLE_DEFAULTS.get(data.get("role", role or "macbook"), {}))
    merged.update(data)
    if role and "role" not in data:
        merged["role"] = role
    merged.update({k: v for k, v in overrides.items() if v is not None})
    merged["path"] = str(p)
    known = {f for f in Profile.__dataclass_fields__}
    return Profile(**{k: v for k, v in merged.items() if k in known})


def write_profile(profile: Profile, path: str | Path | None = None) -> Path:
    p = Path(path).expanduser() if path else profile_path_for(profile.role)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(profile.to_yaml())
    return p
