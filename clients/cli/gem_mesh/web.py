"""Shim-side web search for public queries.

Claude Code's WebSearch is a server tool that runs on Anthropic's API, so it cannot exist on the local path.
The shim offers its own `web_search` tool instead and executes it itself (the model's call never reaches
Claude Code), the way a server tool would. It is only offered when the conversation is public, and every
query is checked against the privacy rules again before it leaves the machine.
"""
from __future__ import annotations

import html
import re

import httpx

TOOL = {"type": "function", "function": {
    "name": "web_search",
    "description": ("Search the web for current, public information: weather, news, prices, opening hours, documentation. "
                    "Returns titles, links, snippets, and the most relevant text of the top pages, so the answer is usually in the result. "
                    "The query leaves the user's devices: use only general, public terms. Never include client, company, person "
                    "or project names, emails, amounts or anything else from the conversation that is private."),
    "parameters": {"type": "object", "properties": {"query": {"type": "string", "description": "the search query"}},
                   "required": ["query"]}}}

_RESULT = re.compile(r'class="result__a" href="([^"]+)"[^>]*>(.*?)</a>.*?class="result__snippet"[^>]*>(.*?)</a>', re.S)


def _clean(s: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", "", s)).strip()


def _url(href: str) -> str:
    m = re.search(r"uddg=([^&]+)", href)
    if m:
        from urllib.parse import unquote
        return unquote(m.group(1))
    return href if href.startswith("http") else "https:" + href if href.startswith("//") else href


UA = {"User-Agent": "Mozilla/5.0 (Macintosh) gem-mesh"}
_STOP = {"the", "and", "for", "what", "whats", "how", "hows", "with", "from", "this", "that", "about", "near", "right", "now"}


def page_text(url: str) -> str:
    r = httpx.get(url, timeout=10.0, follow_redirects=True, headers=UA)
    r.raise_for_status()
    s = re.sub(r"(?is)<(script|style|noscript|svg|head|nav|footer)[^>]*>.*?</\1>", " ", r.text)
    s = html.unescape(re.sub(r"<[^>]+>", " ", s))
    s = re.sub(r"\s+", " ", s).strip()
    s = re.sub(r"(\d)\s*°\s*([CF])\b", r"\1°\2", s)      # "59° F" → "59°F"
    s = re.sub(r"(\d)\s+%", r"\1%", s)
    return s


def best_passage(text: str, query: str, width: int = 1500) -> str:
    """The window of the page that mentions the query's words (and numbers) most."""
    words = [w for w in re.findall(r"[a-z0-9]+", query.lower()) if len(w) > 2 and w not in _STOP]
    if len(text) <= width or not words:
        return text[:width]
    low = text.lower()
    best, best_i = -1, 0
    for i in range(0, len(text) - width + 1, 250):
        win = low[i:i + width]
        score = 3 * sum(win.count(w) for w in words) + 0.05 * len(re.findall(r"\d", win))
        if score > best:
            best, best_i = score, i
    return ("…" if best_i else "") + text[best_i:best_i + width] + "…"


def search(query: str, limit: int = 6, read: int = 3, width: int = 1500) -> str:
    """Results with titles, links and snippets, plus the most relevant passage of the top `read` pages."""
    r = httpx.post("https://html.duckduckgo.com/html/", data={"q": query}, timeout=15.0, headers=UA)
    r.raise_for_status()
    hits = [(_clean(m.group(2)), _url(m.group(1)), _clean(m.group(3))) for m in list(_RESULT.finditer(r.text))[:limit]]
    if not hits:
        return "No results."
    from concurrent.futures import ThreadPoolExecutor
    def grab(u):
        try:
            return best_passage(page_text(u), query, width=width)
        except Exception as e:
            return f"(could not read page: {type(e).__name__})"
    with ThreadPoolExecutor(max_workers=len(hits)) as ex:
        passages = list(ex.map(grab, [u for _, u, _ in hits]))
    # Keep the `read` most informative passages (JS-rendered pages come back nearly empty).
    words = [w for w in re.findall(r"[a-z0-9]+", query.lower()) if len(w) > 2 and w not in _STOP]
    def info(t: str) -> float:
        lt = t.lower()
        return 3 * sum(lt.count(w) for w in words) + 0.05 * len(re.findall(r"\d", t)) + min(len(t), 1500) / 500
    keep = set(sorted(range(len(passages)), key=lambda i: -info(passages[i]))[:read])
    out = []
    for i, (title, url, snip) in enumerate(hits):
        out.append(f"{i+1}. {title}\n   {url}\n   {snip}")
        if i in keep:
            out.append(f"   Page text: {passages[i]}")
    return "\n".join(out)
