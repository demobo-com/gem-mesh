"""The privacy and capability router, v0: rules + difficulty + tier window + node selection.

Night-one scope: deterministic rules decide public vs sensitive; the on-device classifier is added
later behind the same interface. Every decision carries its log lines for the CLI and the badge.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .nodes import NodeInfo
from .policy import Policy


def estimate_tokens(text: str) -> int:
    return max(1, len(text) // 4)


@dataclass
class Decision:
    privacy: str                         # public | sensitive
    reasons: list[str]
    floor: str
    ceiling: str
    chosen: NodeInfo | None
    needs: str | None = None             # tier required when nothing reachable fits
    frontier_offer: bool = False         # public request, frontier allowed with approval
    log: list[str] = field(default_factory=list)

    def summary(self) -> str:
        if self.chosen:
            return f"{self.chosen.device} / {self.chosen.model}"
        return f"queued: needs {self.needs}"


def classify_rules(text: str, policy: Policy) -> tuple[str, list[str]]:
    hits: list[str] = []
    for rule in policy.rules:
        m = rule.regex.search(text)
        if m:
            hits.append(f'rule hit "{m.group(0)[:40]}" ({rule.name})')
    low = text.lower()
    for term in policy.terms:
        if term.lower() in low:
            hits.append(f'rule hit "{term}" (custom term)')
    return ("sensitive" if hits else "public"), hits


def route(prompt: str, nodes: list[NodeInfo], policy: Policy, context_tokens: int = 0,
          mode: str = "office", prefer_tier: str | None = None, classifier=None, scan_text: str | None = None,
          need_tokens: int | None = None) -> Decision:
    """`scan_text` is everything the privacy check must see (the whole conversation); defaults to the prompt.
    A conversation that has been sensitive once stays sensitive."""
    log: list[str] = []
    privacy, reasons = classify_rules(scan_text if scan_text is not None else prompt, policy)
    if privacy == "public" and classifier is not None:
        label, why = classifier(prompt)
        if label in ("sensitive", "unknown"):
            privacy = "sensitive"
            reasons.append(f"classifier: {label} ({why})")
        else:
            reasons.append(f"classifier: public ({why})")
    if reasons:
        for r in reasons:
            log.append(f"route  {r} → {privacy}")
    else:
        log.append(f"route  no rule hit → {privacy}")

    win = policy.windows.get(privacy) or {"floor": "T0", "ceiling": "T3"}
    floor, ceiling = win["floor"], win["ceiling"]
    prefer = floor
    total = estimate_tokens(prompt) + context_tokens
    why = []
    if total > int(policy.difficulty.get("heavy_tokens", 12000)):
        prefer = max(prefer, "T2", key=policy.rank); floor = max(floor, "T1", key=policy.rank); why.append(f"{total:,} tokens, heavy")
    elif total > int(policy.difficulty.get("long_prompt_tokens", 1500)):
        prefer = max(prefer, "T1", key=policy.rank); floor = max(floor, "T1", key=policy.rank); why.append(f"{total:,} tokens, long")
    if prefer_tier and policy.rank(prefer_tier) > policy.rank(prefer):
        prefer = prefer_tier; why.append(f"preferred {prefer_tier}")
    log.append(f"route  window {floor}…{ceiling}, prefer {prefer}" + (f" ({', '.join(why)})" if why else ""))

    lo, hi, pr = policy.rank(floor), policy.rank(ceiling), policy.rank(prefer)
    cands = [n for n in nodes if n.tier != "?" and lo <= policy.rank(n.tier) <= hi]
    if need_tokens:
        small = [n for n in cands if n.max_num_tokens and n.max_num_tokens < need_tokens]
        for n in small:
            log.append(f"route  skip {n.device}: window {n.max_num_tokens:,} < ~{need_tokens:,} tokens needed")
        cands = [n for n in cands if n not in small]
    key = lambda n: (n.load, n.latency_ms if n.latency_ms is not None else 9e9)
    at_or_above = sorted([n for n in cands if policy.rank(n.tier) >= pr], key=lambda n: (policy.rank(n.tier), *key(n)))
    below = sorted([n for n in cands if policy.rank(n.tier) < pr], key=lambda n: (-policy.rank(n.tier), *key(n)))
    chosen = at_or_above[0] if at_or_above else (below[0] if below else None)
    fell_back = chosen is not None and not at_or_above
    frontier_offer = privacy == "public" and policy.frontier == "ask" and mode != "offline"
    if chosen:
        if fell_back:
            log.append(f"route  {prefer} not reachable, falling back within window")
        log.append(f"route  → {chosen.device} / {chosen.model} ({chosen.tier}" + (f", load {chosen.load:.2f}" if chosen.load else "") + ")")
    else:
        log.append(f"route  nothing reachable in {floor}…{ceiling} → queue (needs {floor})")
    return Decision(privacy=privacy, reasons=reasons, floor=floor, ceiling=ceiling, chosen=chosen,
                    needs=None if chosen else floor, frontier_offer=frontier_offer, log=log)
