# policy

Deployment-editable files shared by every client, Python and Android alike.

- `rules.yaml` — deterministic privacy rules (keys, emails, paths, custom terms). A hit is sensitive.
- `classifier.txt` — the prompt for the on-device classifier (E4B on the phone, the hosted model elsewhere).
- `tiers.yaml` — tier floors and ceilings per privacy class, frontier policy (never / ask).
- `models.yaml` — the model catalog (repo, file, size) and the default model per role; the installer and `scripts/models.py` read it.
- `golden/*.json` — labelled cases every router implementation must pass.
