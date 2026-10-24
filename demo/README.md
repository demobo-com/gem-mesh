# demo

`files/` is the sandbox for demos. Mention a file by name in `gem-mesh` or `gem-mesh-mobile` and it is
attached to your question automatically (the Android app also attaches a file named as spoken words, such as "negotiation
notes" for negotiation-notes.md):

    What is unusual in this lease acme-lease.txt
    Summarize hr-review-notes.md in three bullets
    What do I still need to do before the trip? lisbon-trip.md
    Who owns the open items in sprint-notes.md?

The chats can also change files here, after you approve each change (old versions go to `.versions/`):

    Read acme-lease.txt and acme-invoice.pdf and write a one-page memo for the partner as acme-memo.pdf, then stamp it CONFIDENTIAL
    Turn lisbon-trip.md into a PDF called lisbon-trip.pdf
    Look at my Milo photos. Which one is best to share?
    Brighten the Milo photos, crop them square and take the location off before I share them
    Make a collage of the Milo photos called milo-collage.jpg
    Add the caption "Milo's evening at the park" under milo-park-1.jpg

Photo vision runs on the device's own E4B (the phone stand-in's model; the laptop chat loads one on first use).
Use a copy for rehearsals so the originals stay put: `MESH_FILES_DIR=/tmp/demo-files gem-mesh-mobile` after
`cp -r demo/files /tmp/demo-files`. Optional: Claude Code on the mesh, `cd demo/files && gem-mesh code`.

| File | Scenario | Routing it shows |
|---|---|---|
| acme-lease.txt | Work · law firm (~4K tokens, client "Acme", rent figures; landlord-only break, relocation, catering monopoly, liability waiver, personal guarantees) | sensitive, heavy → workstation |
| hr-review-notes.md | Work · HR (names, salary) | sensitive, short → laptop; no web |
| lisbon-trip.md | Companion / travel (personal plans) | public; web allowed for checks like opening hours |
| sprint-notes.md | Code / team | public, short |
| acme-invoice.pdf | Work · law firm invoice (client, amounts) | sensitive; with the lease → memo PDF on the workstation |
| q3-update.pdf | Work · public product update, 2 pages | PDF stamp, page edits, word edits |
| milo-park-1/2/3.jpg | Companion · evening photos of the dog, a bit dark, with Pixel 11 camera data and the home GPS location | photo vision and editing on the phone; location removed before sharing |
| city-sunset.png | Generic image | resize, caption, convert |
| key-numbers.md | AGI House demo (`demo/script.md`) · the founder's numbers, short | phone |
| eval-report.md | AGI House demo · private benchmark report, ~1.7K tokens | sensitive, long → laptop |
| negotiation-notes.md | AGI House demo · walk-away terms, ~1.6K tokens | sensitive, long → laptop |
| term-sheet.md | AGI House demo · Series A term sheet; with the negotiation notes, ~3.1K tokens | sensitive, heavy → workstation |
| whiteboard.jpg | AGI House demo · stand-in photo of Dana's whiteboard ($180M pre, 1.5x participating, 2 seats) | photo vision on the phone, answer on the laptop |
| term-sheet-photo.jpg | AGI House demo · stand-in photo of the printed term sheet's first page | photo vision on the phone |
