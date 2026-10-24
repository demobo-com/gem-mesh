# core (meshcore)

Shared Python library: discovery (mDNS `_local-ai._tcp`), router (rules + classifier + tier window), node client, memory store and sync, task queue, profiles, policy loader. Every Python client and the node import this; the Android and iOS ports mirror it and pass the same golden tests.
