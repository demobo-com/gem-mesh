# clients/cli

The `gem-mesh` command: one Python package for the laptop chat, the phone stand-in, the operator tools and the
optional Claude Code shim. `gem-mesh --help` lists everything.

- `gem-mesh` (or `gem-mesh chat`): the laptop's chat. Routes each request (rules, on-device classifier, tier window),
  shows the decision and a badge, and offers the model these tools: web search and fetch (query checked first),
  workspace files (read, write, edit; PDF and image actions; `look_at_image` with on-device vision), and memory
  (remember, recall). File changes wait for your yes. Memory is a mirror of the phone's.
- `gem-mesh-mobile`: the phone stand-in. Same chat with E4B (or E2B) in-process, memory authority on :9401, queue for
  work that needs a bigger tier; web questions are handed up to a bigger node when one is reachable.
- `gem-mesh ask "<q>"`, `gem-mesh route "<q>"`, `gem-mesh nodes`, `gem-mesh memory ...`: one-shot versions.
- `gem-mesh model`: the model this node serves, what is downloaded, and what fits this machine. `gem-mesh model 12b`
  (or `26b`, `31b`, `e4b`, `e2b`, or a full id) switches it: downloads if needed, sets the context size for that model,
  restarts the node.
- `gem-mesh role`: this machine's role. `gem-mesh role workstation` makes it a bigger node (T2) for the other devices;
  `gem-mesh role laptop` switches it back (T1, its own node plus the chat). Both re-run the installer with that role.
- `gem-mesh pair`: what a phone needs to reach this Mac (address, checks, QR code). Pairing is optional: open by
  default (anyone on the network can use the node, your risk). `gem-mesh pair --secure` makes the mesh private
  (HTTPS, mesh key, mesh-only certificate authority); `gem-mesh pair --open` undoes it.
- `gem-mesh join '<code>'`: put a workstation or another Mac into a paired mesh, with the code `gem-mesh pair`
  prints on the Mac that created it.
- `gem-mesh node`, `gem-mesh doctor`, `gem-mesh models`, `gem-mesh profile`, `gem-mesh plan`: the node server and operator tools
  (the same as the older `meshnode` and `mesh` commands, which remain for running services).
- `gem-mesh code [...]`: optional. Claude Code with every model call answered by the mesh through the Anthropic
  Messages-API shim on :8790 (`gem-mesh shim`). Install it with `./install.sh --with-shim`, which also adds `/tier`
  inside Claude Code.

In a chat: `/help`, `/tier T0|T1|T2|auto`, `/think on|off|auto`, `/network office|airplane|offline|auto`,
`/hide <device>`, `/queue`, `/memory`, `/remember`, `/recall`, `/frontier <question>`, `/phone <task>`, `/reset`.

`/phone <task>` hands one task to AGI's phone agent (MCP at `api.agi.tech/v1/mcp`), which taps and types on a phone
that runs the AGI app with its accessibility service on. Only the task is checked and shown; a private task is flagged
with the reason but not refused. After a yes it goes to AGI, and so does a screenshot of every step (about $0.01 a step,
at most 200). Ctrl-C stops the task on the phone.

Environment: `MESH_FILES_DIR` (the workspace folder, default `demo/files`), `MESH_HOME` (default `~/.gem-mesh`),
`MESH_IGNORE=dev1,dev2` (pretend those devices are away), `MESH_NATIVE_LOGS=1` (LiteRT-LM's own logging),
`AGI_API_KEY` (for `/phone`, from platform.agi.tech), `MESH_AGI_URL` (another MCP endpoint for `/phone`).
