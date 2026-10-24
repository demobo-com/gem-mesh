# servers/litert (meshnode)

The backbone server, identical on the MacBook (T1, 26B), the workstation (T2, 31B) and a private server (T3): the profile sets tier and model, LiteRT-LM picks the GPU path. It is an OpenAI-compatible API around the LiteRT-LM `Engine`, one live conversation per session id, idle eviction, mDNS advertisement with tier, models and load. Runs as a login service installed by `scripts/install.sh`.

Sibling folders are reserved for adapters that let an existing OpenAI-compatible server (vLLM, Ollama) join the mesh by advertising the same record: `servers/vllm/`, `servers/ollama/`.
