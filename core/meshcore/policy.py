"""Policy files: model catalog, privacy rules, tier windows. All deployment-editable YAML."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

import yaml


@dataclass
class ModelSpec:
    id: str
    repo: str
    file: str
    bytes: int

    @property
    def url(self) -> str:
        return f"https://huggingface.co/{self.repo}/resolve/main/{self.file}"


@dataclass
class Rule:
    name: str
    regex: re.Pattern


@dataclass
class Policy:
    dir: Path
    models: dict[str, ModelSpec]
    roles: dict[str, dict]
    rules: list[Rule]
    terms: list[str]
    tiers: dict[str, dict]
    windows: dict[str, dict]
    difficulty: dict
    frontier: str = "ask"
    web: str = "public"
    effort: dict = field(default_factory=dict)
    classifier: bool = True
    classifier_prompt: str = ""
    warnings: list[str] = field(default_factory=list)

    def rank(self, tier: str) -> int:
        return int(self.tiers.get(tier, {}).get("rank", 99))

    def tier_for_rank(self, rank: int) -> str:
        for name, t in self.tiers.items():
            if int(t.get("rank", -1)) == rank:
                return name
        return f"T{rank}"

    def sizing_for_role(self, role: str, ram_gb: float | None = None, model: str | None = None) -> dict:
        """Model and limits for this role on this machine: the by_ram row that fits the memory, or the row for an
        explicitly chosen model. Keys: model, and when known context, sessions, vision."""
        r = self.roles.get(role) or {}
        rows = sorted(r.get("by_ram") or [], key=lambda x: -float(x.get("min_ram_gb", 0)))
        if model:
            row = next((x for x in rows if x.get("model") == model), None)
            return dict(row or {}, model=model)
        if rows and ram_gb is not None:
            row = next((x for x in rows if ram_gb >= float(x.get("min_ram_gb", 0))), rows[-1])
            return dict(row)
        return {"model": r.get("model") or "gemma4-26b", **(dict(rows[0]) if rows and rows[0].get("model") == r.get("model") else {})}

    def model_for_role(self, role: str, ram_gb: float | None = None) -> str:
        return self.sizing_for_role(role, ram_gb)["model"]

def _load_yaml(p: Path) -> dict:
    return (yaml.safe_load(p.read_text()) or {}) if p.exists() else {}


def load_policy(policy_dir: Path) -> Policy:
    policy_dir = Path(policy_dir)
    warnings: list[str] = []
    models_doc = _load_yaml(policy_dir / "models.yaml")
    rules_doc = _load_yaml(policy_dir / "rules.yaml")
    tiers_doc = _load_yaml(policy_dir / "tiers.yaml")
    for name, doc in (("models.yaml", models_doc), ("rules.yaml", rules_doc), ("tiers.yaml", tiers_doc)):
        if not doc:
            warnings.append(f"{name} missing or empty in {policy_dir}")
    models = {k: ModelSpec(id=k, **v) for k, v in (models_doc.get("models") or {}).items()}
    rules: list[Rule] = []
    for r in rules_doc.get("patterns") or []:
        try:
            rules.append(Rule(r["name"], re.compile(r["regex"], re.I)))
        except re.error as e:
            warnings.append(f"rule {r.get('name')} has a bad regex: {e}")
    return Policy(
        dir=policy_dir,
        models=models,
        roles=models_doc.get("roles") or {},
        rules=rules,
        terms=[str(t) for t in (rules_doc.get("terms") or [])],
        tiers=tiers_doc.get("tiers") or {"T0": {"rank": 0}, "T1": {"rank": 1}, "T2": {"rank": 2}, "T3": {"rank": 3}, "T4": {"rank": 4, "frontier": True}},
        windows=tiers_doc.get("windows") or {"public": {"floor": "T0", "ceiling": "T3"}, "sensitive": {"floor": "T0", "ceiling": "T3"}},
        difficulty=tiers_doc.get("difficulty") or {"long_prompt_tokens": 1500, "heavy_tokens": 12000},
        frontier=str(tiers_doc.get("frontier", "ask")),
        web=str(tiers_doc.get("web", "public")),
        effort=dict(tiers_doc.get("effort") or {}),
        classifier=str(tiers_doc.get("classifier", "on")).lower() in ("on", "true", "yes", "1"),
        classifier_prompt=(policy_dir / "classifier.txt").read_text() if (policy_dir / "classifier.txt").exists() else "",
        warnings=warnings,
    )
