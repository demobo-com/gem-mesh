#!/usr/bin/env bash
# Gem Mesh installer. Idempotent: re-running keeps downloaded models, rewrites the profiles, restarts the node.
#
#   ./install.sh                       # on a Mac: the Mac's node and chat, models sized to this Mac's memory
#   ./install.sh --size small          # force a size: xl (26B) | large (12B) | medium (E4B) | small (E2B)
#   ./install.sh --model gemma4-e4b    # or name the laptop model exactly (see: gem-mesh models list)
#   ./install.sh --yes                 # do not ask before downloading
#   ./install.sh --dev                 # developers: also the phone stand-in (gem-mesh-mobile), for work without a phone
#   ./install.sh --no-service          # do not register the node as a login service
#   ./install.sh --with-shim           # also run the optional Claude Code shim (gem-mesh code)
#   ./install.sh --role workstation    # a workstation node: M5 Ultra Mac Studio, or Linux + NVIDIA (detected on Linux)
set -euo pipefail

ROLE="" MODEL="" SIZE="" DEVICE="" SERVICE=1 PORT="" SHIM=0 PHONE=0 YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    --dev) PHONE=1; shift ;;
    --no-phone) PHONE=0; shift ;;   # the default; kept for older instructions
    --no-service) SERVICE=0; shift ;;
    --with-shim) SHIM=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option $1 (see --help)"; exit 2 ;;
  esac
done
case "$SIZE" in
  "") ;; xl) MODEL=gemma4-26b ;; large) MODEL=gemma4-12b-gpu ;; medium) MODEL=gemma4-e4b ;; small) MODEL=gemma4-e2b ;;
  *) echo "--size must be xl, large, medium or small"; exit 2 ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OS="$(uname -s)"; ARCH="$(uname -m)"
say() { printf '\033[1m==\033[0m %s\n' "$*"; }
die() { printf '\033[31mxx\033[0m %s\n' "$*"; exit 1; }

# 1. role
if [ -z "$ROLE" ]; then
  if [ "$OS" = Darwin ]; then
    [ "$ARCH" = arm64 ] || die "Gem Mesh needs an Apple silicon Mac (M1 or later); this one is $ARCH."
    ROLE=macbook
  elif [ "$OS" = Linux ] && command -v nvidia-smi >/dev/null 2>&1; then ROLE=workstation
  elif [ "$OS" = Linux ]; then ROLE=server
  else die "cannot detect a role on $OS/$ARCH; pass --role"; fi
fi
[ "$ROLE" = macbook ] || PHONE=0
say "role: $ROLE  ($OS/$ARCH)"

# 2. uv and the workspace (Python 3.12 managed by uv; nothing installed system-wide)
if ! command -v uv >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/uv" ]; then
  say "installing uv into ~/.local/bin"
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
UV="$(command -v uv || echo "$HOME/.local/bin/uv")"
say "syncing the workspace"
cd "$REPO"
"$UV" python install 3.12 >/dev/null
"$UV" sync --quiet
BIN="$REPO/.venv/bin"

# 3. sizing: what fits this machine
if [ "$ROLE" = macbook ]; then
  eval "$("$BIN/gem-mesh" plan ${MODEL:+--model "$MODEL"})"
  MODELS="$(printf '%s\n' "$LAPTOP_MODEL" "$VISION_MODEL" embeddinggemma-2 $( [ "$PHONE" = 1 ] && echo "$PHONE_MODEL" ) | sort -u | tr '\n' ' ')"
  FREE_GB="$(df -g "$HOME" | awk 'NR==2{print $4}')"
  say "this Mac: ${RAM_GB} GB memory, ${FREE_GB} GB free disk"
  echo "   laptop model   $LAPTOP_MODEL  (context ${CONTEXT} tokens)"
  [ "$PHONE" = 1 ] && echo "   phone stand-in $PHONE_MODEL  (developer tool: gem-mesh-mobile)"
  echo "   photo vision   $VISION_MODEL"
  echo "   downloads      up to ${DOWNLOAD_GB} GB into ~/.litert-lm/models (files already there are skipped)"
  awk -v f="$FREE_GB" -v d="$DOWNLOAD_GB" 'BEGIN{exit !(f < d + 5)}' && die "not enough free disk: need about $(awk -v d="$DOWNLOAD_GB" 'BEGIN{print d+5}') GB. Try --size small."
  if [ "$YES" = 0 ] && [ -t 0 ]; then
    read -r -p "   continue? [Y/n] " ans; case "$ans" in n|N|no) echo "stopped; nothing downloaded"; exit 0 ;; esac
  fi
  MODEL="$LAPTOP_MODEL"
fi

# 4. profiles
ARGS=(--role "$ROLE" profile init)
[ -n "$DEVICE" ] && ARGS+=(--device "$DEVICE")
[ -n "$MODEL" ] && ARGS+=(--model "$MODEL")
say "writing the profile"
"$BIN/mesh" "${ARGS[@]}" | head -1
if [ -n "$PORT" ]; then
  PF="$("$BIN/mesh" --role "$ROLE" profile show | tail -1 | sed 's/^# //')"
  sed -i.bak "s/^node_port: .*/node_port: $PORT/" "$PF" && rm -f "$PF.bak"
fi
if [ "$PHONE" = 1 ]; then
  "$BIN/mesh" --role mobile-mock profile init --model "$PHONE_MODEL" | head -1
fi

# 5. models
if [ "$ROLE" = macbook ]; then
  for m in $MODELS; do say "model: $m"; "$BIN/mesh" --role "$ROLE" models pull "$m"; done
else
  M="$("$BIN/mesh" --role "$ROLE" profile show | awk '/^model:/{print $2}')"
  say "model: $M"; "$BIN/mesh" --role "$ROLE" models pull "$M"
fi

# 6. commands on PATH
mkdir -p "$HOME/.local/bin"
for c in gem-mesh gemmesh mesh meshnode $( [ "$PHONE" = 1 ] && echo gem-mesh-mobile ); do ln -sf "$BIN/$c" "$HOME/.local/bin/$c"; done
for c in claude-local claude-local-macbook claude-local-mobile covey gemma-mesh gemma-mesh-mobile; do   # names from before the rename
  [ -L "$HOME/.local/bin/$c" ] && rm -f "$HOME/.local/bin/$c"
done
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) say "add ~/.local/bin to your PATH to use gem-mesh from anywhere" ;; esac

# 7. the node as a login service
HOMEDIR="$("$BIN/python" -c 'from meshcore.profile import MESH_HOME; print(MESH_HOME)')"
mkdir -p "$HOMEDIR"
if [ "$SERVICE" = 1 ]; then
  LOG="$HOMEDIR/node.log"
  RARG=""; [ "$ROLE" != macbook ] && RARG="--role $ROLE"
  if [ "$OS" = Darwin ]; then
    for old in com.localaimesh.meshnode com.localaimesh.shim com.covey.node com.covey.shim com.gemma-mesh.node com.gemma-mesh.shim; do      # labels from before the rename
      launchctl bootout "gui/$(id -u)/$old" 2>/dev/null || true; rm -f "$HOME/Library/LaunchAgents/$old.plist"
    done
    PL="$HOME/Library/LaunchAgents/com.gem-mesh.node.plist"; mkdir -p "$(dirname "$PL")"
    cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.gem-mesh.node</string>
  <key>ProgramArguments</key><array><string>$BIN/gem-mesh</string><string>node</string>$( [ -n "$RARG" ] && printf '<string>--role</string><string>%s</string>' "$ROLE" )</array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string><key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PLIST
    launchctl bootout "gui/$(id -u)/com.gem-mesh.node" 2>/dev/null || true
    lsof -tiTCP:"$("$BIN/mesh" --role "$ROLE" profile show | awk '/^node_port:/{print $2}')" -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true
    # launchd can still be unloading the old service for a moment after bootout: retry instead of failing silently
    for _ in 1 2 3 4 5 6 7 8 9 10; do launchctl bootstrap "gui/$(id -u)" "$PL" 2>/dev/null && break; sleep 1; done
    launchctl print "gui/$(id -u)/com.gem-mesh.node" >/dev/null 2>&1 || die "launchd did not start com.gem-mesh.node; run ./install.sh again"
    say "node registered with launchd as com.gem-mesh.node (log: $LOG)"
  elif [ "$OS" = Linux ] && command -v systemctl >/dev/null 2>&1; then
    U="$HOME/.config/systemd/user/gem-mesh-node.service"; mkdir -p "$(dirname "$U")"
    for oldu in meshnode covey-node gemma-mesh-node; do   # unit names from before the rename
      systemctl --user disable --now "$oldu.service" 2>/dev/null || true; rm -f "$HOME/.config/systemd/user/$oldu.service"
    done
    cat > "$U" <<UNIT
[Unit]
Description=Gem Mesh node ($ROLE)
After=network-online.target
[Service]
ExecStart=$BIN/gem-mesh node $RARG
Restart=on-failure
StandardOutput=append:$LOG
StandardError=append:$LOG
[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now gem-mesh-node.service
    systemctl --user restart gem-mesh-node.service
    say "node registered with systemd --user as gem-mesh-node (log: $LOG)"
  fi
  say "waiting for the node to load its model"
  P="$("$BIN/mesh" --role "$ROLE" profile show | awk '/^node_port:/{print $2}')"
  for _ in $(seq 1 120); do curl -s -m 2 "http://127.0.0.1:$P/health" >/dev/null && break; sleep 2; done
fi

# 7b. optional: the Claude Code shim (gem-mesh code), macOS only
if [ "$SERVICE" = 1 ] && [ "$SHIM" = 1 ] && [ "$ROLE" = macbook ] && [ "$OS" = Darwin ]; then
  SP="$HOME/Library/LaunchAgents/com.gem-mesh.shim.plist"
  cat > "$SP" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.gem-mesh.shim</string>
  <key>ProgramArguments</key><array><string>$BIN/gem-mesh</string><string>shim</string></array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOMEDIR/shim.log</string><key>StandardErrorPath</key><string>$HOMEDIR/shim.log</string>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/com.gem-mesh.shim" 2>/dev/null || true
  lsof -tiTCP:8790 -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do launchctl bootstrap "gui/$(id -u)" "$SP" 2>/dev/null && break; sleep 1; done
  mkdir -p "$HOME/.claude/commands"; ln -sf "$REPO/clients/cli/commands/tier.md" "$HOME/.claude/commands/tier.md"
  say "Claude Code shim on :8790 (gem-mesh code), and /tier inside Claude Code"
fi

# 8. check
say "gem-mesh doctor"
"$BIN/gem-mesh" doctor ${ROLE:+--role "$ROLE"} || true
if [ "$ROLE" = macbook ]; then
  cat <<NEXT

Ready. Start the chat:
  gem-mesh
Then ask, for example:
  Summarize acme-lease.txt and flag anything unusual
  Look at my Milo photos. Which one is best to share?
  Brighten the Milo photos, crop them square and take the location off before I share them
Demo files are in $REPO/demo/files. Type /help in a chat.
With the Android app: run  gem-mesh pair  and scan the code on the phone.
NEXT
else
  M="$("$BIN/mesh" --role "$ROLE" profile show | awk '/^model:/{print $2}')"
  cat <<NEXT

Ready: this $ROLE serves $M as a login service on port $("$BIN/mesh" --role "$ROLE" profile show | awk '/^node_port:/{print $2}').
MacBooks and phones on the same network find it by themselves. From a MacBook, check:
  gem-mesh nodes
Different network or VPN? Add http://<this machine's address>:9400 under static_nodes in the MacBook's profile.
NEXT
fi
