"""meshcore: the shared library of the Gem Mesh.

Discovery over mDNS, the privacy router, node clients (remote HTTP and local in-process),
profiles and policy loading. Every Python client and the node server import this.
"""

__version__ = "0.1.0"


def quiet_native_logs() -> None:
    """LiteRT-LM's C++ loader prints model-loading chatter (missing vision/audio sections, accelerator registration,
    no NPU) straight to the terminal. Keep errors only, unless MESH_NATIVE_LOGS=1 asks for everything."""
    import os
    if os.environ.get("MESH_NATIVE_LOGS"):
        return
    try:
        from litert_lm import LogSeverity, set_min_log_severity
        set_min_log_severity(LogSeverity.ERROR)
    except Exception:
        pass
