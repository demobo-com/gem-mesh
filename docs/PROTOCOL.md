# Gem Mesh wire protocol

Everything a client needs to talk to the rest of a Gem Mesh mesh. The Python code is the reference implementation;
where this page and the code disagree, the code wins and this page has a bug.

| Piece | Reference code |
|---|---|
| Discovery (mDNS) | `core/meshcore/discovery.py` |
| Node API (OpenAI-compatible) | `servers/litert/meshnode/app.py`, `core/meshcore/engine.py` |
| Router | `core/meshcore/router.py`, `policy/tiers.yaml`, `policy/rules.yaml`, `policy/classifier.txt` |
| Memory sync | `core/meshcore/memory.py`, `core/meshcore/memory_server.py` |
| Tools and approvals | `clients/cli/gem_mesh/session.py`, `clients/cli/gem_mesh/files.py`, `clients/cli/gem_mesh/web.py` |
| Malformed tool-call repair | `core/meshcore/toolparse.py` |

## 1. Discovery

Nodes advertise `_local-ai._tcp.local.` over mDNS (the name follows the LYiHub local-ai-discovery TXT convention,
so other tools can find Gem Mesh nodes and the other way round). Instance name `<device>-<tier>`, e.g. `my-macbook-t1`.

TXT record (all strings):

| Key | Example | Meaning |
|---|---|---|
| `v` | `1` | record version |
| `api` | `openai` | API style |
| `base` | `/v1` | API base path |
| `auth` | `none` | no auth inside the mesh |
| `models` | `/v1/models` | model list path |
| `mesh` | `default` | mesh name; ignore nodes from another mesh |
| `tier` | `T1` | T0 phone · T1 laptop · T2 workstation · T3 server |
| `model` | `gemma4-26b` | model id from `policy/models.yaml` |
| `device` | `my-macbook` | device name |
| `load` | `0.25` | 0 idle … 1 busy, refreshed every 15 s |

A phone announces its **memory service** on the same service type with `api=memory`, `base=/memory`, `tier=T0`,
its `device` and `mesh`, instance `<device>-memory`, port 9401. It is never a place to send chat; the laptop's
mirror syncs with it (section 4). Clients that do not know `api=memory` must skip any record whose `api` is not
`openai`.

**Pairing code** (`gem-mesh pair` prints it as JSON and a QR code), for networks where mDNS does not work:
`{"v":1,"app":"gem-mesh","mesh":"default","nodes":["http://192.168.1.20:9400"],"device":"my-macbook"}`.
The app keeps the listed nodes as static nodes and still health-checks them.

A node counts as **reachable** only while `GET /health` answers within about 2 s (checked every few seconds). An
mDNS record alone is not enough: a frozen node or a stale address must not attract traffic. The phone never
advertises a model; it is a client (and the memory authority, section 4).

Where mDNS cannot cross (VPN, some guest Wi-Fi), a profile can list `static_nodes: [http://host:9400]`.

## 2. Node API

Port 9400 by default. All JSON.

- `GET /health` → `{"status": "ok"}`
- `GET /mesh/info` → `{"device","tier","model","mesh","role","sessions","max_sessions","generating","max_num_tokens","load",
  "tokens_in","tokens_out","tokens_cached", ...}`. `max_num_tokens` is the node's context window; the router skips
  nodes whose window is too small. `tokens_*` are the node's totals since it started, every client and side request
  (classifier, fact extraction) included.
- `GET /v1/models` → OpenAI list with one model.
- `POST /v1/chat/completions` → OpenAI chat completions, streaming (`"stream": true`, SSE) or not, with tools.

Request fields beyond OpenAI's:

| Field | Meaning |
|---|---|
| `session_id` (or header `X-Session-Id`) | keeps the conversation's KV cache on the node between turns; send the same id every turn |
| `ephemeral: true` | one-off request (classifier, fact extraction): no cache kept |
| `thinking: true` | let the model reason first (Gemma 4 thinking, 1,024-token budget on top of `max_tokens`) |

Tools: OpenAI `tools: [{"type":"function","function":{name, description, parameters}}]`. The node never runs a
tool. It returns `tool_calls` (ids are minted by the node), the client runs them and sends the results back as
`{"role":"tool","tool_call_id":...,"content":...}` messages, exactly as with OpenAI. Send the assistant message
with its `tool_calls` back unchanged; the node recognises its own turns by call id and reuses the cache.

**Usage.** Real token counts, from LiteRT-LM's counters: `usage: {"prompt_tokens","completion_tokens","total_tokens",
"prompt_tokens_details": {"cached_tokens"}}`. `prompt_tokens` is the whole prompt; `cached_tokens` is the part a
reused session already held in its KV cache, so `prompt_tokens - cached_tokens + completion_tokens` is the work this
turn cost. Streamed, `usage` rides on the chunk that carries `finish_reason`; with `stream_options.include_usage`
OpenAI's usage-only chunk (`choices: []`) follows it. Nodes before 23 Oct 2026 report zeros: clients then estimate.

The response carries a `mesh` object: `{"device","tier","session_id","reused"}`. Errors: `{"error":{"message","type","code"}}`;
status 400 with `code: context_length_exceeded` when the input is larger than the window, 503 when busy.

**Malformed tool calls.** Small models sometimes write a call LiteRT-LM cannot parse (a missing comma). The node
answers 500 with the raw block in the message (`Failed to parse tool calls from code block: call:name{...}`) and
does not reset. Clients repair it with the lenient parser in `toolparse.py` (Gemma writes
`call:name{key:<|"|>text<|"|>,n:3}`), or retry once.

## 3. Routing (runs on the client, before any text leaves the device)

1. **Rules** (`rules.yaml`): regex patterns and custom terms over the whole conversation, not just the last
   message. Any hit makes the conversation **sensitive**, and it stays sensitive.
2. **Classifier** (`classifier.txt`): if no rule hits, the device's own model labels the conversation
   `public | sensitive | unknown`; `unknown` counts as sensitive. Ephemeral request, never leaves the mesh.
3. **Window** (`tiers.yaml`): floor and ceiling per class. Size raises the floor: estimated tokens
   (`len(text) // 4`, prompt plus history plus attachments) above `long_prompt_tokens` (1500) → floor T1;
   above `heavy_tokens` (3000) → prefer T2, floor T1.
4. **Node**: among reachable nodes inside the window, the lowest tier at or above the preferred one (ties: lower
   load, then lower latency). If none, the highest below it but still inside the window ("falling back"). If
   nothing fits, the task is **queued** with the floor it needs and runs when such a node returns.

The frontier (Gemini) is never chosen by the router. It is offered only for public conversations, and only after
the user sees the exact text and approves.

`policy/golden/*.json` holds the cases every implementation must pass (`eval/test_golden.py` for Python).

## 4. Memory sync (phone is the authority)

The phone holds the user's memory and serves it on port 9401 while the app runs; the laptop keeps a mirror.

Event (one row; ids are global, so copies merge with insert-or-ignore):

```json
{"id": "my-phone:42", "device": "my-phone", "seq": 42, "ts": 1761170000.5,
 "kind": "fact", "session": "a1b2c3", "role": null, "text": "The user's sister Mia lives in Lisbon.",
 "meta": {"source": "extracted"}}
```

`kind` is `chat` (a turn), `fact` (a lasting fact about the user), `doc` (a document chunk) or `forget`.
`meta.web: true` marks answers built from the web; recall skips them (they go stale).

**Forgetting.** Memory is append-only, so forgetting is an event too, and syncs like the rest:

```json
{"id": "my-phone:57", "device": "my-phone", "seq": 57, "ts": 1761171000.0, "kind": "forget",
 "session": null, "role": null, "text": "forgot: The user's sister Mia lives in Lisbon.",
 "meta": {"targets": ["my-phone:42"]}}
```

A device that writes or receives a forget event deletes the targets and their vectors, keeps the forget event (so
the other side still pulls or receives it), and remembers the target ids: an event it has forgotten is never
ingested again, whichever side sends an old copy. A forget event is never itself a target and is not embedded.
Forgetting a conversation names all its turns; forgetting everything names every event. Devices from before 24
Oct 2026 store forget events without acting on them.

An assistant `chat` event's `meta` says how the turn ran; every client writes the same keys:

| Key | Meaning |
|---|---|
| `node`, `model`, `tier` | who answered (`tier` T0 the phone … T4 the frontier) |
| `privacy` | `public` or `sensitive`, as the router decided |
| `route` | the router's log lines |
| `left` | what left the mesh: `"0 bytes left the mesh"`, `"nothing left the phone"`, `"412 bytes left the mesh (approved)"` |
| `seconds`, `thinking` | time to the full answer; whether the model reasoned first |
| `tokens_in`, `tokens_out`, `tokens_cached` | the turn's tokens, every model call of it summed (tool rounds included): prompt, generated, and the part of the prompt already cached |
| `tokens_est: true` | a model reported no usage and 4 characters were counted as a token |
| `web: true` | built from the web |

Older events may lack any of these; readers fall back (no tier: look up the node).

- `GET /memory/pull?after=<rowid>&limit=500` → `{"events": [...], "last": <rowid>}` (the authority's own row order)
- `POST /memory/push` with `{"events": [...]}` → `{"accepted": n}` (new ones only)
- `GET /memory/status` → counts

The mirror finds the phone through its mDNS memory record (or a pinned `memory_peer` in the profile), pushes its
outbox (events it wrote while the phone was away), then pulls everything after its cursor, every 20 s. Vectors are not synced: each device embeds with EmbeddingGemma (768 dims, normalised; query prefix
`task: search result | query: `, document prefix `title: none | text: `) and searches facts and documents.

## 5. Tools the chat offers the model

Defined in `session.py` (web, files, memory) and `files.py` (file actions). The client runs every tool.

| Tool | Runs | Notes |
|---|---|---|
| `web_search`, `fetch` | client, over the internet | only the query or URL leaves; each is checked against the rules and blocked on a hit; the phone hands web questions to a bigger node |
| `list_files`, `read_file` | client | the workspace folder only; PDFs as text, images as facts (size, exposure, date, camera, GPS warning) |
| `remember`, `recall` | client | memory store above |
| `look_at_image` | client, on-device vision model (E2B/E4B) | up to four images in one message, labelled by file name |
| `write_file`, `edit_file`, `pdf_pages`, `edit_image`, `make_image` | client, **after the user approves** | see below |

**Approvals.** A file action is planned first (what will change, a preview), shown to the user, and applied only
on an explicit yes; the default is no. Names are bare file names inside the workspace. The previous version goes
to `<workspace>/.versions/`. Work that runs in the background (the queue) never gets file actions.

**Photo actions** (`edit_image`): `enhance`, `square`, `remove_location` (strip EXIF GPS and camera data),
`resize` (keeps proportions), `crop`, `rotate`, `grayscale`, `warm`, `flip`, `caption`, `convert`; comma-combined;
`name` can be a pattern (`milo-*.jpg`) for one approval over several photos.

## 6. Pairing and security

Pairing is optional, and it changes the whole mesh.

| | Open (default) | Paired (`gem-mesh pair --secure`) |
|---|---|---|
| Transport | plain HTTP | HTTPS, every node and memory server |
| Who can use a node or read a phone's memory | anyone on the network (the owner's risk) | only devices holding the mesh key |
| Which nodes a device trusts | any node announcing the mesh name | only nodes whose certificate the mesh authority signed |
| mDNS TXT | as in section 1 | adds `tls=1`, `ca=<first 16 hex of the authority fingerprint>` |

**Secrets** (on the Mac that ran `--secure`, in `~/.gem-mesh/mesh/`): a mesh key (32 random bytes, URL-safe
base64), a mesh certificate authority (EC P-256, 10 years), and the node's certificate signed by it. Code:
`core/meshcore/security.py`.

**Pairing code** (`gem-mesh pair` prints it as JSON and QR):

```json
{"v":2,"app":"gem-mesh","mesh":"default","nodes":["https://192.168.1.20:9400"],"device":"my-macbook",
 "key":"<mesh key>","ca":"<SHA-256 of the authority certificate's DER, 64 hex>"}
```

`v:1` codes (no `key`, `ca`, `http://` node) mean the mesh is open. The code holds the key: show it only to your own
devices.

**Joining** (a phone, a workstation, another Mac). On a Mac or workstation this is `gem-mesh join '<code>'`; the
phone apps do the same steps after scanning the QR code:
1. `GET <node>/mesh/ca` (open, no key) → `{"ca_pem", "fingerprint"}`. Compute SHA-256 of the certificate's DER and
   compare with the code's `ca`. Mismatch: stop, show an error, store nothing.
2. Trust exactly that authority for every later connection: verify the chain to it, **do not check the host name**
   (addresses change; only this authority can sign).
3. `POST <node>/mesh/enroll` with `Authorization: Bearer <key>` and `{"device": "<name>", "role": "phone"}` →
   `{"cert_pem", "key_pem", "ca_pem", "fingerprint"}`: this device's own certificate and private key, for its memory
   server. Store the key in the platform keystore.
4. Store the mesh key; send `Authorization: Bearer <key>` on every request.

**Rules for a paired device:**
- Use only nodes and memory records with `tls=1` and `ca` equal to the first 16 hex of the authority fingerprint;
  connect over HTTPS and verify against the authority. Ignore everything else, even with the same mesh name.
- Serve the memory server over HTTPS with the enrolled certificate; reject requests without the mesh key (401
  `pairing_required`); announce `tls=1` and `ca`.
- `/health` and `/mesh/ca` are the only endpoints that answer without the key.

**An open device in a paired mesh** sees `tls=1` records and must skip them (it cannot use them). **Undo:**
`gem-mesh pair --open` moves the secrets aside and restarts the node; paired devices must forget the Mac.

Reference test: `eval/test_pairing.py` (17 checks: plain HTTP refused, key required, foreign authorities rejected,
join with a matching and a mismatching code, discovery filtering including a fake open node, memory sync).
