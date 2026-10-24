#!/usr/bin/env bash
# File-action checks for both chats: create/edit text, PDF and image files, and private photo editing, with approval.
# Works on a scratch copy of demo/files, so the demo folder is never changed. Needs the MacBook node. About 2 minutes.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"; BIN="$REPO/.venv/bin"
WS="$(mktemp -d)/files"; cp -r demo/files "$WS"; export MESH_FILES_DIR="$WS"
PASS=0; FAIL=0; RESULTS=()
clean() { sed 's/\x1b\[[0-9;]*m//g'; }
check() {  # name, regex that must appear, command...
  local name="$1" want="$2"; shift 2
  local out; out="$("$@" 2>&1 | clean)"
  if echo "$out" | grep -qE "$want"; then PASS=$((PASS+1)); RESULTS+=("PASS  $name"); else FAIL=$((FAIL+1)); RESULTS+=("FAIL  $name   (wanted /$want/)"); echo "--- $name ---"; echo "$out" | tail -8; fi
}
exists() { [ -f "$WS/$1" ] && echo "exists $1" || echo "missing $1"; }
chat() { if [ "$1" = phone ]; then printf "$2" | "$BIN/gem-mesh" phone; else printf "$2" | "$BIN/gem-mesh"; fi; }

check "laptop: write a text file (approved)"   "Done: created note.txt"   chat laptop 'Save a two-line note to the landlord asking to remove the relocation clause as note.txt\ny\n'
check "  file is on disk"                       "exists note.txt"          exists note.txt
check "laptop: make a PDF from a document"     "Done: created .*\.pdf"    chat laptop 'Turn lisbon-trip.md into a PDF called lisbon-trip.pdf\ny\n'
check "laptop: stamp a PDF"                    "stamped 'DRAFT'"          chat laptop 'Stamp DRAFT on every page of q3-update.pdf\ny\n'
check "laptop: edit the words in a PDF"        "rewrote q3-update.pdf"    chat laptop 'In q3-update.pdf change "1,240" to "1,260"\ny\n'
check "laptop: declined change writes nothing" "declined"                 chat laptop 'Rotate city-sunset.png 90 degrees and save as turned.png\nn\n'
check "  declined file is absent"               "missing turned.png"       exists turned.png
check "laptop: make an image"                  "Done: made invite.png"    chat laptop 'Make an invite image called invite.png for team dinner Friday 7pm at Taberna\ny\n'
check "phone alone: write and edit a file"     "Done: edited groceries"   chat phone 'Save a shopping list as groceries.txt: eggs, milk, bread\ny\nAdd coffee to groceries.txt\ny\n' 
check "phone alone: edit an image"             "Done: (resize|convert)"   bash -c "printf 'Resize city-sunset.png to 400 pixels wide, save as small.png\ny\n' | $BIN/gem-mesh-mobile --network offline"
check "photos: phone looks at the photos"      "look_at_image .*on device \(vision\)" bash -c "printf 'Look at my Milo photos. Which one is best to share?\n' | $BIN/gem-mesh-mobile --network offline"
check "laptop: sees an image via on-device E4B" "look_at_image"           chat laptop 'What does city-sunset.png show?\n'
check "photos: location noticed before sharing" "(GPS|location)"           bash -c "printf 'Anything I should know before sharing milo-park-1.jpg?\n' | $BIN/gem-mesh-mobile --network offline"
check "photos: enhance, square, strip location" "Location removed"        bash -c "printf 'Brighten the Milo photos, crop them square and take the location off before I share them\ny\n' | $BIN/gem-mesh-mobile --network offline"
check "  photos have no GPS left"               "no camera metadata"       "$BIN/python" -c "
from gem_mesh import files as F; print(F.image_facts(F.find('milo-park-2.jpg')))"
check "photos: collage"                         "collage of 3 photos"      bash -c "printf 'Make a collage of the Milo photos called milo-collage.jpg\ny\n' | $BIN/gem-mesh-mobile --network offline"
check "guard: no paths outside the workspace"  "Invalid file name"        "$BIN/python" -c "
from gem_mesh import files as F
try: F.plan_action('write_file', {'name': '/etc/hosts', 'content': 'x'})
except F.FileError as e: print(e)"
check "guard: queued tasks cannot write"       "need the user's approval" "$BIN/python" -c "
from gem_mesh.session import ClientSession
s = ClientSession.start(role='macbook', quiet=True)
print(s.run_tool('write_file', {'name': 'q.txt', 'content': 'x'}, [], approve=None)); s.close()"
echo "== summary =="; printf '%s\n' "${RESULTS[@]}"; echo "$PASS passed, $FAIL failed · workspace $WS"; [ "$FAIL" = 0 ]
