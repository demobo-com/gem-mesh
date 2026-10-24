"""Pairing and transport security for a mesh.

Pairing is optional. An unpaired mesh is open: plain HTTP on the local network, usable by anyone on it, at the
owner's risk. `gem-mesh pair` makes the mesh secure:

  * a random mesh key (bearer token on every request except /health and /mesh/ca);
  * a mesh certificate authority (EC P-256) that only this mesh uses; every node, and every enrolled phone or
    machine, serves HTTPS with a certificate it signed;
  * clients trust exactly that authority (pinned by its SHA-256 fingerprint from the pairing code) and do not check
    host names, so a device whose Wi-Fi address changes stays trusted, while a device outside the mesh cannot be;
  * a paired device uses only nodes that pass this check, so a fake node on the network gets nothing.

Files live in <MESH_HOME>/mesh/: key, ca.pem, ca.key (only on the device that created the mesh), cert.pem, cert.key.
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import hmac
import ipaddress
import json
import secrets
import shutil
import ssl
import time
from dataclasses import dataclass
from pathlib import Path

from .profile import MESH_HOME

MESH_DIR = MESH_HOME / "mesh"
OPEN_PATHS = {"/health", "/mesh/ca"}


def _x509():
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID
    return x509, hashes, serialization, ec, NameOID


def fingerprint(pem: str | bytes) -> str:
    """SHA-256 of the certificate's DER encoding, lowercase hex (what the pairing code carries)."""
    x509, hashes, serialization, _, _ = _x509()
    cert = x509.load_pem_x509_certificate(pem.encode() if isinstance(pem, str) else pem)
    return cert.fingerprint(hashes.SHA256()).hex()


def _key_pem(key) -> str:
    _, _, serialization, _, _ = _x509()
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                             serialization.NoEncryption()).decode()


def _cert(subject_cn: str, pub, issuer_cn: str, signing_key, ca: bool, days: int, sans: list[str] | None = None):
    x509, hashes, serialization, ec, NameOID = _x509()
    now = _dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(minutes=5)
    b = (x509.CertificateBuilder()
         .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, subject_cn)]))
         .issuer_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, issuer_cn)]))
         .public_key(pub).serial_number(x509.random_serial_number())
         .not_valid_before(now).not_valid_after(now + _dt.timedelta(days=days))
         .add_extension(x509.BasicConstraints(ca=ca, path_length=0 if ca else None), critical=True))
    if ca:
        b = b.add_extension(x509.KeyUsage(digital_signature=True, key_cert_sign=True, crl_sign=True, content_commitment=False,
                                          key_encipherment=False, data_encipherment=False, key_agreement=False,
                                          encipher_only=False, decipher_only=False), critical=True)
    else:
        names = []
        for s in sans or []:
            try:
                names.append(x509.IPAddress(ipaddress.ip_address(s)))
            except ValueError:
                names.append(x509.DNSName(s))
        if names:
            b = b.add_extension(x509.SubjectAlternativeName(names), critical=False)
        b = b.add_extension(x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.SERVER_AUTH,
                                                   x509.oid.ExtendedKeyUsageOID.CLIENT_AUTH]), critical=False)
    return b.sign(signing_key, hashes.SHA256())


@dataclass
class Mesh:
    dir: Path
    key: str

    @property
    def ca_pem(self) -> Path: return self.dir / "ca.pem"
    @property
    def cert_pem(self) -> Path: return self.dir / "cert.pem"
    @property
    def cert_key(self) -> Path: return self.dir / "cert.key"
    @property
    def can_enroll(self) -> bool: return (self.dir / "ca.key").exists()

    def ca_fingerprint(self) -> str:
        return fingerprint(self.ca_pem.read_bytes())

    def check_bearer(self, header: str | None) -> bool:
        token = (header or "").removeprefix("Bearer ").strip()
        return bool(token) and hmac.compare_digest(token, self.key)

    def client_ssl(self) -> ssl.SSLContext:
        """Trust exactly this mesh's authority; no host-name check (addresses move, the authority does not)."""
        ctx = ssl.create_default_context(cafile=str(self.ca_pem))
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_REQUIRED
        return ctx

    def httpx_kwargs(self) -> dict:
        return {"verify": self.client_ssl(), "headers": {"Authorization": f"Bearer {self.key}"}}

    def issue(self, name: str, sans: list[str] | None = None, days: int = 825) -> tuple[str, str]:
        """A certificate and private key for a device joining this mesh (only where the authority's key lives)."""
        x509, hashes, serialization, ec, NameOID = _x509()
        ca_key = serialization.load_pem_private_key((self.dir / "ca.key").read_bytes(), password=None)
        ca = x509.load_pem_x509_certificate(self.ca_pem.read_bytes())
        k = ec.generate_private_key(ec.SECP256R1())
        cn = ca.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
        cert = _cert(name, k.public_key(), cn, ca_key, ca=False, days=days, sans=sans)
        return cert.public_bytes(serialization.Encoding.PEM).decode(), _key_pem(k)


def load(home: Path | None = None) -> Mesh | None:
    d = (home / "mesh") if home else MESH_DIR
    try:
        key = (d / "key").read_text().strip()
    except OSError:
        return None
    if not key or not (d / "ca.pem").exists() or not (d / "cert.pem").exists():
        return None
    return Mesh(d, key)


def create(device: str, mesh_name: str = "default", sans: list[str] | None = None, home: Path | None = None) -> Mesh:
    """New mesh secrets on this device: key, authority, and this device's own certificate."""
    x509, hashes, serialization, ec, NameOID = _x509()
    d = (home / "mesh") if home else MESH_DIR
    d.mkdir(parents=True, exist_ok=True)
    d.chmod(0o700)
    ca_key = ec.generate_private_key(ec.SECP256R1())
    cn = f"gem-mesh {mesh_name} {secrets.token_hex(4)}"
    ca = _cert(cn, ca_key.public_key(), cn, ca_key, ca=True, days=3650)
    _write(d / "ca.key", _key_pem(ca_key), private=True)
    _write(d / "ca.pem", ca.public_bytes(serialization.Encoding.PEM).decode())
    _write(d / "key", secrets.token_urlsafe(32), private=True)
    m = Mesh(d, (d / "key").read_text().strip())
    cert, key = m.issue(device, sans=(sans or []) + ["localhost", "127.0.0.1"])
    _write(d / "cert.pem", cert)
    _write(d / "cert.key", key, private=True)
    return m


def join(code: dict, device: str, role: str, home: Path | None = None, timeout: float = 10.0) -> Mesh:
    """Join a secure mesh from a pairing code: fetch the authority, check its fingerprint, enroll with the key."""
    import httpx
    d = (home / "mesh") if home else MESH_DIR
    url = (code.get("nodes") or [None])[0]
    if not url or not code.get("key") or not code.get("ca"):
        raise ValueError("this pairing code has no secure mesh in it (run gem-mesh pair on the Mac that created it)")
    ca_pem = httpx.get(f"{url}/mesh/ca", verify=False, timeout=timeout).json()["ca_pem"]   # checked by fingerprint next
    if fingerprint(ca_pem) != code["ca"]:
        raise ValueError("the authority this node offers does not match the pairing code; not joining")
    d.mkdir(parents=True, exist_ok=True); d.chmod(0o700)
    _write(d / "ca.pem", ca_pem)
    ctx = ssl.create_default_context(cafile=str(d / "ca.pem")); ctx.check_hostname = False
    r = httpx.post(f"{url}/mesh/enroll", json={"device": device, "role": role}, verify=ctx, timeout=timeout,
                   headers={"Authorization": f"Bearer {code['key']}"})
    r.raise_for_status()
    e = r.json()
    _write(d / "cert.pem", e["cert_pem"]); _write(d / "cert.key", e["key_pem"], private=True)
    _write(d / "key", code["key"], private=True)
    return Mesh(d, code["key"])


def leave(home: Path | None = None) -> Path | None:
    """Back to an open mesh: move the secrets aside (kept, in case this was a mistake)."""
    d = (home / "mesh") if home else MESH_DIR
    if not d.exists():
        return None
    dest = d.with_name(f"mesh-removed-{time.strftime('%Y%m%d-%H%M%S')}")
    shutil.move(str(d), str(dest))
    return dest


def pairing_code(m: Mesh | None, device: str, mesh_name: str, node_url: str | None) -> dict:
    code = {"v": 2 if m else 1, "app": "gem-mesh", "mesh": mesh_name, "nodes": [node_url] if node_url else [], "device": device}
    if m:
        code.update(key=m.key, ca=m.ca_fingerprint())
    return code


def _write(p: Path, text: str, private: bool = False) -> None:
    p.write_text(text)
    if private:
        p.chmod(0o600)
