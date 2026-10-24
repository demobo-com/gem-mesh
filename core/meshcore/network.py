"""Network mode detection: office, airplane (phone hotspot), offline. Detected, not configured;
`override` exists for scripted demos."""
from __future__ import annotations

import platform
import re
import subprocess
from dataclasses import dataclass


@dataclass
class NetworkState:
    mode: str                 # office | airplane | offline
    ssid: str | None
    gateway: str | None
    detail: str

    def describe(self) -> str:
        return {"office": f"{self.ssid or 'wired'} Wi-Fi", "airplane": f"airplane mode · hotspot {self.ssid or ''}".strip(),
                "offline": "no network"}.get(self.mode, self.mode)


def _run(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=4).stdout
    except Exception:
        return ""


def current_ssid() -> str | None:
    sysname = platform.system()
    if sysname == "Darwin":
        out = _run(["ipconfig", "getsummary", "en0"])
        m = re.search(r"^\s*SSID\s*:\s*(.+)$", out, re.M)
        if m:
            return m.group(1).strip()
        out = _run(["networksetup", "-getairportnetwork", "en0"])
        m = re.search(r"Current Wi-Fi Network:\s*(.+)", out)
        return m.group(1).strip() if m else None
    if sysname == "Linux":
        out = _run(["iwgetid", "-r"]).strip()
        if out:
            return out
        out = _run(["nmcli", "-t", "-f", "active,ssid", "dev", "wifi"])
        for line in out.splitlines():
            if line.startswith("yes:"):
                return line.split(":", 1)[1]
    return None


def default_gateway() -> str | None:
    sysname = platform.system()
    if sysname == "Darwin":
        out = _run(["route", "-n", "get", "default"])
        m = re.search(r"gateway:\s*(\S+)", out)
        return m.group(1) if m else None
    if sysname == "Linux":
        out = _run(["ip", "route", "show", "default"])
        m = re.search(r"default via (\S+)", out)
        return m.group(1) if m else None
    return None


HOTSPOT_GATEWAYS = ("172.20.10.", "192.168.43.", "192.168.44.")
HOTSPOT_SSID_HINTS = ("iphone", "pixel", "galaxy", "android", "hotspot")


def detect(override: str | None = None, hotspot_ssids: list[str] | None = None, office_ssids: list[str] | None = None) -> NetworkState:
    ssid = current_ssid()
    gw = default_gateway()
    if override:
        return NetworkState(mode=override, ssid=ssid, gateway=gw, detail="override")
    if not gw:
        return NetworkState(mode="offline", ssid=ssid, gateway=None, detail="no default route")
    s = (ssid or "").lower()
    if ssid and hotspot_ssids and ssid in hotspot_ssids:
        return NetworkState("airplane", ssid, gw, "hotspot ssid from profile")
    if any(gw.startswith(p) for p in HOTSPOT_GATEWAYS) or any(h in s for h in HOTSPOT_SSID_HINTS):
        return NetworkState("airplane", ssid, gw, "hotspot gateway/ssid pattern")
    if ssid and office_ssids and ssid not in office_ssids:
        return NetworkState("office", ssid, gw, "unknown wifi, treated as office")
    return NetworkState("office", ssid, gw, "wifi or wired with gateway")
