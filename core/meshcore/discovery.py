"""mDNS discovery on `_local-ai._tcp.local.`, compatible with the LYiHub local-ai-discovery TXT record
(v, api, base, auth) plus mesh fields: tier, model, device, load, mesh.

Advertise from a node; browse from a client. A NodeTable merges mDNS, static URLs from the profile,
and the in-process local node, and refreshes load/latency by polling /mesh/info.
"""
from __future__ import annotations

import os
import socket
import threading
import time

from zeroconf import IPVersion, ServiceBrowser, ServiceInfo, ServiceStateChange, Zeroconf

from .nodes import LocalNode, NodeInfo, RemoteNode

SERVICE_TYPE = "_local-ai._tcp.local."


def _own_ips() -> list[str]:
    """The address other machines should use: the default-route interface only.

    Advertising every local address leaks virtual bridges (vmnet, docker) that peers then pick
    and cannot reach, so only the primary LAN address is published.
    """
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        s.close()
        if not ip.startswith("127."):
            return [ip]
    except OSError:
        pass
    return []


class Advertiser:
    def __init__(self, device: str, tier: str, model: str, port: int, mesh: str = "default", load_fn=None,
                 api: str = "openai", base: str = "/v1", extra: dict[str, str] | None = None):
        """api "openai" is a model node (base /v1). api "memory" is a phone serving its memory (base /memory):
        clients never route chat to it; the laptop's mirror syncs with it."""
        self.device, self.tier, self.model, self.port, self.mesh = device, tier, model, port, mesh
        self.api, self.base = api, base
        self.extra = dict(extra or {})       # e.g. tls=1, ca=<first 16 hex of the mesh authority fingerprint>
        self.load_fn = load_fn or (lambda: 0.0)
        self.zc: Zeroconf | None = None
        self.info: ServiceInfo | None = None
        self._stop = threading.Event()

    def _props(self) -> dict[str, str]:
        props = {"v": "1", "api": self.api, "base": self.base, "auth": "none",
                 "mesh": self.mesh, "tier": self.tier, "model": self.model, "device": self.device,
                 "load": f"{self.load_fn():.2f}"}
        if self.api == "openai":
            props["models"] = "/v1/models"
        props.update(self.extra)
        return props

    def _service(self, ips: list[str]) -> ServiceInfo:
        suffix = self.tier.lower() if self.api == "openai" else self.api
        return ServiceInfo(SERVICE_TYPE, f"{self.device}-{suffix}.{SERVICE_TYPE}",
                           addresses=[socket.inet_aton(ip) for ip in ips] or None,
                           port=self.port, properties=self._props(), server=f"{self.device}.local.")

    def start(self) -> None:
        self.ips = _own_ips()
        self.zc = Zeroconf(ip_version=IPVersion.V4Only)
        self.info = self._service(self.ips)
        self.zc.register_service(self.info, allow_name_change=True)
        threading.Thread(target=self._refresh, daemon=True).start()

    def _refresh(self) -> None:
        """Every 15 s: re-read the LAN address (DHCP can move it) and the load. Re-register when the address changes."""
        while not self._stop.wait(15):
            try:
                assert self.zc and self.info
                ips = _own_ips()
                if ips != self.ips:
                    self.zc.unregister_service(self.info)
                    self.zc.close()
                    self.zc = Zeroconf(ip_version=IPVersion.V4Only)
                    self.ips = ips
                    self.info = self._service(ips)
                    self.zc.register_service(self.info, allow_name_change=True)
                    print(f"meshnode  address changed, re-advertised on {', '.join(ips) or 'no address'}", flush=True)
                else:
                    self.info._set_properties(self._props())
                    self.zc.update_service(self.info)
            except Exception as e:
                print(f"meshnode  advertise refresh failed: {e}", flush=True)

    def stop(self) -> None:
        self._stop.set()
        if self.zc and self.info:
            try:
                self.zc.unregister_service(self.info)
            finally:
                self.zc.close()


class NodeTable:
    """Live view of reachable nodes. Start once per client process."""

    def __init__(self, mesh: str = "default", static_urls: list[str] | None = None, local: LocalNode | None = None,
                 poll_seconds: float = 5.0, stale_seconds: float = 20.0, security="auto"):
        """security: the paired mesh (meshcore.security.Mesh), None for open, "auto" to load it from MESH_HOME.
        Paired: only nodes announcing TLS with this mesh's authority are used, over HTTPS with the mesh key.
        Open: nodes of a paired mesh are skipped (without the key they would refuse anyway)."""
        if security == "auto":
            from . import security as _sec
            security = _sec.load()
        self.security = security
        self._ca16 = security.ca_fingerprint()[:16] if security else None
        self._client_kw = security.httpx_kwargs() if security else None
        self.mesh = mesh
        self.poll_seconds = poll_seconds
        self.stale_seconds = stale_seconds
        self._remote: dict[str, RemoteNode] = {}
        self._memory: dict[str, tuple[str, str, float]] = {}   # mDNS name → (device, base url, seen)
        self._lock = threading.Lock()
        self.local = local
        self.zc: Zeroconf | None = None
        self._browser: ServiceBrowser | None = None
        self._stop = threading.Event()
        for url in static_urls or []:
            url = url.rstrip("/")
            if self.security and url.startswith("http://"):
                url = "https://" + url[len("http://"):]        # a paired mesh speaks only HTTPS
            self._remote[url] = RemoteNode(NodeInfo(name=url, device=url, tier="?", model="?", base_url=url, source="static"),
                                           secure=self._client_kw)

    # mDNS callbacks -------------------------------------------------------
    def _on_change(self, zeroconf: Zeroconf, service_type: str, name: str, state_change: ServiceStateChange) -> None:
        if state_change is ServiceStateChange.Removed:
            with self._lock:
                for key, node in list(self._remote.items()):
                    if node.info.name == name and node.info.source == "mdns":
                        self._remote.pop(key, None)
                self._memory.pop(name, None)
            return
        info = zeroconf.get_service_info(service_type, name, timeout=2000)
        if not info:
            return
        props = {k.decode() if isinstance(k, bytes) else k: (v.decode() if isinstance(v, bytes) else v)
                 for k, v in (info.properties or {}).items()}
        if props.get("mesh", "default") != self.mesh:
            return
        addrs = info.parsed_addresses(IPVersion.V4Only)
        if not addrs:
            return
        tls = props.get("tls") == "1"
        if self.security:
            if not tls or props.get("ca") != self._ca16:
                return      # not part of this paired mesh: never send it anything
        elif tls:
            return          # a paired mesh's node; this device is not paired with it
        url = f"{'https' if tls else 'http'}://{addrs[0]}:{info.port}"
        if props.get("api", "openai") == "memory":
            with self._lock:      # a phone's memory service: never a place to send chat
                self._memory[name] = (props.get("device", name.split(".")[0]), url, time.time())
            return
        if props.get("api", "openai") != "openai":
            return
        ni = NodeInfo(name=name, device=props.get("device", name.split(".")[0]), tier=props.get("tier", "?"),
                      model=props.get("model", "?"), base_url=url, load=float(props.get("load", 0) or 0), props=props)
        with self._lock:
            existing = self._remote.get(url)
            if existing:
                # mDNS keeps announcing even when the node's HTTP side is frozen, so it updates metadata only;
                # "seen" (reachability) is refreshed solely by a successful health check.
                existing.info.tier, existing.info.model, existing.info.device = ni.tier, ni.model, ni.device
            else:
                node = RemoteNode(ni, secure=self._client_kw)
                self._remote[url] = node
                threading.Thread(target=node.health, daemon=True).start()   # reachable as soon as it answers

    def start(self) -> "NodeTable":
        self.zc = Zeroconf(ip_version=IPVersion.V4Only)
        self._browser = ServiceBrowser(self.zc, SERVICE_TYPE, handlers=[self._on_change])
        threading.Thread(target=self._poll, daemon=True).start()
        return self

    def _poll(self) -> None:
        while not self._stop.is_set():
            for node in list(self._remote.values()):
                node.health()
            if self.local:
                self.local.health()
            self._stop.wait(self.poll_seconds)

    def refresh(self) -> None:
        for node in list(self._remote.values()):
            node.health()
        if self.local:
            self.local.health()

    def wait(self, seconds: float = 2.0) -> None:
        time.sleep(seconds)
        self.refresh()

    def nodes(self) -> list[NodeInfo]:
        """Reachable nodes. MESH_IGNORE=dev1,dev2 hides devices (scripted tests that simulate a node going away)."""
        now = time.time()
        ignore = {d.strip() for d in os.environ.get("MESH_IGNORE", "").split(",") if d.strip()}
        out: list[NodeInfo] = []
        if self.local:
            out.append(self.local.info)
        with self._lock:
            for node in self._remote.values():
                if now - node.info.seen <= self.stale_seconds and node.info.latency_ms is not None and node.info.device not in ignore:
                    out.append(node.info)
        return out

    def memory_peers(self) -> list[tuple[str, str]]:
        """Phones announcing their memory on this mesh: [(device, http://ip:port)], newest first."""
        with self._lock:
            return [(d, u) for d, u, _ in sorted(self._memory.values(), key=lambda x: -x[2])]

    def all_nodes(self) -> list[NodeInfo]:
        """Every node known, reachable or not (for status displays)."""
        out: list[NodeInfo] = [self.local.info] if self.local else []
        with self._lock:
            out += [n.info for n in self._remote.values()]
        return out

    def client_for(self, info: NodeInfo):
        if info.local:
            return self.local
        with self._lock:
            return self._remote.get(info.base_url or "")

    def stop(self) -> None:
        self._stop.set()
        if self.zc:
            self.zc.close()
