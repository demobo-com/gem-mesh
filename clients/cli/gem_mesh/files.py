"""Workspace files for the chats: read, create and edit text, PDF and image files in the demo folder.

Every change is planned first and applied only after the user approves it in the chat. Nothing outside the
workspace folder can be touched (names are bare file names), and the previous version of a changed file is kept in
<workspace>/.versions/ so a change can be undone by hand.
"""
from __future__ import annotations

import io
import re
import shutil
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

TEXT_EXT = {".txt", ".md", ".csv", ".json", ".yaml", ".yml", ".py", ".log", ".html"}
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp"}
PDF_EXT = {".pdf"}

FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
]
BOLD_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
]


def _font_path(bold: bool = False) -> str | None:
    for f in (BOLD_CANDIDATES if bold else []) + FONT_CANDIDATES:
        if Path(f).exists():
            return f
    return None


class FileError(Exception):
    pass


def workspace() -> Path:
    from .main import demo_dir
    return demo_dir()


def safe_name(name: str) -> str:
    """A bare file name inside the workspace: no folders, no hidden files."""
    raw = (name or "").strip()
    n = Path(raw).name
    if not n or n.startswith(".") or "/" in raw.lstrip("./") or "\\" in raw:
        raise FileError(f"Invalid file name {name!r}. Use a plain name like notes.txt; files stay in the workspace folder.")
    return n


def files() -> list[Path]:
    d = workspace()
    return sorted(p for p in d.iterdir() if p.is_file() and not p.name.startswith(".")) if d.is_dir() else []


def find(name: str) -> Path | None:
    want = (name or "").strip().lower()
    fs = files()
    return (next((p for p in fs if p.name.lower() == want), None)
            or next((p for p in fs if want and Path(want).stem in p.name.lower()), None))


def kind(p: Path) -> str:
    e = p.suffix.lower()
    return "pdf" if e in PDF_EXT else "image" if e in IMAGE_EXT else "text"


# ---- reading -------------------------------------------------------------------------------------------------------
def pdf_text(p: Path, max_chars: int = 24000) -> str:
    from pypdf import PdfReader
    r = PdfReader(str(p))
    parts = []
    for i, page in enumerate(r.pages, 1):
        parts.append(f"[page {i}]\n{(page.extract_text() or '').strip()}")
        if sum(len(x) for x in parts) > max_chars:
            break
    return "\n\n".join(parts)


def photo_meta(im) -> dict:
    """Date, camera and GPS location from EXIF, when present."""
    out = {}
    try:
        ex = im.getexif()
    except Exception:
        return out
    if not ex:
        return out
    cam = " ".join(str(ex.get(t, "")).strip() for t in (0x010F, 0x0110)).strip()
    if cam:
        out["camera"] = cam
    when = ex.get(0x0132) or ex.get_ifd(0x8769).get(0x9003)
    if when:
        out["taken"] = str(when)
    gps = ex.get_ifd(0x8825)
    if gps and 2 in gps and 4 in gps:
        def deg(v):
            d, m, sec = (float(x) for x in v)
            return d + m / 60 + sec / 3600
        lat = deg(gps[2]) * (-1 if gps.get(1) == "S" else 1)
        lon = deg(gps[4]) * (-1 if gps.get(3) == "W" else 1)
        out["location"] = f"{lat:.5f}, {lon:.5f}"
    return out


def image_facts(p: Path) -> str:
    from PIL import Image, ImageStat
    with Image.open(p) as im:
        meta = photo_meta(im)
        rgb = im.convert("RGB")
        bright = sum(ImageStat.Stat(rgb.convert("L")).mean) / 255
        small = rgb.resize((32, 32))
        top = sorted(small.getcolors(32 * 32) or [], reverse=True)[:3]
        hexes = ", ".join("#%02x%02x%02x" % c for _, c in top)
        tone = "dark (underexposed)" if bright < 0.35 else "bright" if bright > 0.7 else "normal exposure"
        parts = [f"image {im.format} {im.width}x{im.height} px, {tone}, main colours {hexes}"]
        if meta:
            parts.append("metadata: " + "; ".join(f"{k} {v}" for k, v in meta.items()))
            if "location" in meta:
                parts.append("Privacy note: the photo carries the GPS location where it was taken, which goes with the file "
                             "when shared; offer to remove it first")
        else:
            parts.append("no camera metadata")
        parts.append("To see what the picture shows, use look_at_image")
        return ". ".join(parts) + "."


def read_any(p: Path, max_chars: int = 24000) -> str:
    k = kind(p)
    if k == "pdf":
        t = pdf_text(p, max_chars)
        from pypdf import PdfReader
        return f"PDF, {len(PdfReader(str(p)).pages)} page(s):\n{t[:max_chars]}"
    if k == "image":
        return image_facts(p)
    t = p.read_text(errors="replace")
    return t[:max_chars] + ("\n[truncated]" if len(t) > max_chars else "")


def describe(p: Path) -> str:
    """One line for list_files."""
    try:
        k = kind(p)
        if k == "pdf":
            from pypdf import PdfReader
            r = PdfReader(str(p))
            first = next((l.strip() for l in (r.pages[0].extract_text() or "").splitlines() if l.strip()), "") if r.pages else ""
            return f"PDF, {len(r.pages)} page(s): {first[:80]}"
        if k == "image":
            from PIL import Image
            with Image.open(p) as im:
                m = photo_meta(im)
                return (f"image {im.format} {im.width}x{im.height}" + (f", taken {m['taken']}" if "taken" in m else "")
                        + (", has GPS location" if "location" in m else ""))
        return next((l.strip("# ").strip() for l in p.read_text(errors="replace").splitlines() if l.strip()), "")[:90]
    except Exception as e:
        return f"(unreadable: {type(e).__name__})"


# ---- writing helpers -----------------------------------------------------------------------------------------------
def _backup(p: Path) -> None:
    if p.exists():
        v = p.parent / ".versions"
        v.mkdir(exist_ok=True)
        shutil.copy2(p, v / f"{p.stem}.{time.strftime("%Y%m%d-%H%M%S")}-{int(time.time() * 1000) % 1000:03d}{p.suffix}")


def _pdf_doc():
    from fpdf import FPDF
    pdf = FPDF(format="A4")
    pdf.set_auto_page_break(True, margin=18)
    pdf.set_margins(18, 18, 18)
    reg, bold = _font_path(), _font_path(bold=True)
    if reg:
        pdf.add_font("body", "", reg)
        pdf.add_font("body", "B", bold or reg)
        fam, uni = "body", True
    else:
        fam, uni = "helvetica", False
    return pdf, fam, uni


def _clean(s: str, uni: bool) -> str:
    if uni:
        return s
    s = s.replace("—", "-").replace("–", "-").replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"')
    return s.encode("latin-1", "replace").decode("latin-1")


def _pdf_add_text(pdf, fam: str, uni: bool, text: str, title: str | None = None) -> None:
    pdf.add_page()
    if title:
        pdf.set_font(fam, "B", 18)
        pdf.multi_cell(0, 9, _clean(title, uni), new_x="LMARGIN", new_y="NEXT")
        pdf.ln(3)
    for line in text.splitlines():
        s = line.rstrip()
        if not s:
            pdf.ln(3); continue
        m = re.match(r"^(#{1,3})\s+(.*)", s)
        if m:
            pdf.ln(2)
            pdf.set_font(fam, "B", {1: 16, 2: 14, 3: 12}[len(m.group(1))])
            pdf.multi_cell(0, 7, _clean(m.group(2), uni), new_x="LMARGIN", new_y="NEXT")
            continue
        pdf.set_font(fam, "", 11)
        b = re.match(r"^\s*[-*•]\s+(.*)", s)
        if b:
            item = b.group(1)
            box = re.match(r"^\[( |x|X)\]\s*(.*)", item)
            if box:
                mark = ("☑ " if box.group(1).lower() == "x" else "☐ ") if uni else ("[x] " if box.group(1).lower() == "x" else "[ ] ")
                line_ = mark + box.group(2)
            else:
                line_ = "• " + item
            pdf.set_x(pdf.l_margin + 4)
            pdf.multi_cell(0, 5.5, _clean(line_.replace("**", ""), uni), new_x="LMARGIN", new_y="NEXT")
        else:
            pdf.multi_cell(0, 5.5, _clean(s.replace("**", ""), uni), new_x="LMARGIN", new_y="NEXT")


def pdf_to_markup(text: str) -> tuple[str | None, str]:
    """Rebuild light structure from extracted PDF text: first line is the title, short lines before bullets are headings."""
    lines = [l.rstrip() for l in re.sub(r"^\[page \d+\]\n?", "", text, flags=re.M).splitlines()]
    while lines and not lines[0].strip():
        lines.pop(0)
    title = lines.pop(0).strip() if lines else None
    out = []
    for i, l in enumerate(lines):
        st = l.strip()
        nxt = next((x.strip() for x in lines[i + 1:] if x.strip()), "")
        if st.startswith("•"):
            out.append("- " + st.lstrip("• ").strip())
        elif st and len(st) < 60 and not st.endswith((".", ":", ",")) and re.match(r"^([•\-*]|\d+\.)", nxt):
            out.append("## " + st)
        else:
            out.append(l)
    return title, "\n".join(out)


def make_pdf_bytes(text: str, title: str | None = None) -> bytes:
    pdf, fam, uni = _pdf_doc()
    _pdf_add_text(pdf, fam, uni, text, title)
    return bytes(pdf.output())


def _font(size: int, bold: bool = False):
    from PIL import ImageFont
    f = _font_path(bold)
    try:
        return ImageFont.truetype(f, size) if f else ImageFont.load_default(size)
    except Exception:
        return ImageFont.load_default()


def _wrap(draw, text: str, font, width: int) -> list[str]:
    out = []
    for para in text.splitlines() or [""]:
        words, line = para.split(), ""
        for w in words:
            t = (line + " " + w).strip()
            if draw.textlength(t, font=font) <= width:
                line = t
            else:
                if line:
                    out.append(line)
                line = w
        out.append(line)
    return out


def _hex(c: str | None, default: str) -> str:
    c = (c or "").strip().lstrip("#")
    return "#" + c if re.fullmatch(r"[0-9a-fA-F]{6}", c) else default


# ---- planned actions -------------------------------------------------------------------------------------------------
@dataclass
class Plan:
    summary: str                 # what will happen, shown to the user before approval
    preview: str                 # content excerpt or details
    apply: Callable[[], str]     # does it; returns the result for the model


def plan_action(name: str, args: dict) -> Plan:
    if name == "write_file":
        return _plan_write(args)
    if name == "edit_file":
        return _plan_edit(args)
    if name == "pdf_pages":
        return _plan_pdf(args)
    if name == "edit_image":
        return _plan_image(args)
    if name == "make_image":
        return _plan_make_image(args)
    raise FileError(f"Unknown action {name}.")


def _target(name: str) -> Path:
    n = safe_name(name)
    d = workspace()
    d.mkdir(parents=True, exist_ok=True)
    return d / n


def _plan_write(a: dict) -> Plan:
    p = _target(a.get("name", ""))
    content = a.get("content") or ""
    if not content.strip():
        raise FileError("Nothing to write: content is empty.")
    verb = "overwrite" if p.exists() else "create"
    k = kind(p)
    if k == "image":
        raise FileError("write_file cannot make images; use make_image.")

    def go() -> str:
        _backup(p)
        if k == "pdf":
            p.write_bytes(make_pdf_bytes(content, a.get("title")))
        else:
            p.write_text(content if content.endswith("\n") else content + "\n")
        return f"Done: {verb}d {p.name} ({p.stat().st_size:,} bytes)." + (" Previous version kept." if verb == "overwrite" else "")
    lines = content.strip().splitlines()
    prev = "\n".join(lines[:12]) + (f"\n… {len(lines) - 12} more line(s)" if len(lines) > 12 else "")
    return Plan(f"{verb} {p.name}" + (" as a PDF" if k == "pdf" else ""), (f"title: {a['title']}\n" if a.get("title") else "") + prev, go)


def _plan_edit(a: dict) -> Plan:
    p = find(a.get("name", ""))
    if not p:
        raise FileError(f"No file named {a.get('name')!r}. Files: " + ", ".join(f.name for f in files()))
    find_s, repl = a.get("find") or "", a.get("replace") or ""
    k = kind(p)
    if k == "image":
        raise FileError("Use edit_image for images.")
    if k == "pdf":
        from pypdf import PdfReader
        pages = [(pg.extract_text() or "") for pg in PdfReader(str(p)).pages]
    else:
        pages = [p.read_text(errors="replace")]
    if a.get("append"):
        add = a["append"].rstrip("\n")
        sep = "" if add.lstrip().startswith((",", ";")) else "\n"     # "…, tomatoes" continues a one-line list
        pages[-1] = pages[-1].rstrip("\n") + sep + (add.strip() if not sep else add) + "\n"
        detail = "+ " + a["append"].strip().replace("\n", "\n+ ")
    else:
        if not find_s:
            raise FileError("Give find and replace, or append.")
        n = sum(t.count(find_s) for t in pages)
        if n == 0:
            raise FileError(f"The text {find_s[:80]!r} is not in {p.name}. Read the file and copy the exact text.")
        pages = [t.replace(find_s, repl) for t in pages]
        detail = f"- {find_s.strip()[:300]}\n+ {repl.strip()[:300]}" + (f"\n({n} places)" if n > 1 else "")

    def go() -> str:
        _backup(p)
        if k == "pdf":
            pdf, fam, uni = _pdf_doc()
            for t in pages:
                title, body = pdf_to_markup(t)
                _pdf_add_text(pdf, fam, uni, body, title)
            p.write_bytes(bytes(pdf.output()))
            return (f"Done: rewrote {p.name} with the change, {len(pages)} page(s); text and simple headings kept, "
                    "original styling replaced. Previous version kept.")
        p.write_text(pages[0])
        return f"Done: edited {p.name}. Previous version kept."
    return Plan(f"edit {p.name}" + (" (the PDF is rebuilt from its text, page by page)" if k == "pdf" else ""), detail, go)


def _pages(spec, total: int) -> list[int]:
    """'1,3-4' or [1,3] → zero-based indexes."""
    if spec in (None, "", "all"):
        return list(range(total))
    if isinstance(spec, int):
        spec = [spec]
    if isinstance(spec, str):
        out = []
        for part in spec.replace(" ", "").split(","):
            if "-" in part:
                a, b = part.split("-", 1)
                out += list(range(int(a), int(b) + 1))
            elif part:
                out.append(int(part))
        spec = out
    idx = sorted({int(i) - 1 for i in spec if 1 <= int(i) <= total})
    if not idx:
        raise FileError(f"No valid pages in {spec!r}; the PDF has {total} page(s).")
    return idx


def _plan_pdf(a: dict) -> Plan:
    from pypdf import PdfReader, PdfWriter
    src = find(a.get("name", ""))
    if not src or kind(src) != "pdf":
        raise FileError(f"No PDF named {a.get('name')!r}. PDFs: " + ", ".join(f.name for f in files() if kind(f) == "pdf"))
    out = _target(a.get("output") or src.name)
    if kind(out) != "pdf":
        raise FileError("output must end in .pdf")
    act = (a.get("action") or "").strip()
    reader = PdfReader(str(src))
    total = len(reader.pages)

    def write(w: PdfWriter, what: str) -> str:
        buf = io.BytesIO(); w.write(buf)
        _backup(out)
        out.write_bytes(buf.getvalue())
        return f"Done: {what}; saved {out.name} ({len(PdfReader(str(out)).pages)} page(s)). " + ("Previous version kept." if out == src else "")

    if act == "add_page":
        text = a.get("text") or ""
        if not text.strip():
            raise FileError("add_page needs text.")
        def go():
            w = PdfWriter(clone_from=reader)
            for pg in PdfReader(io.BytesIO(make_pdf_bytes(text, a.get("title")))).pages:
                w.add_page(pg)
            return write(w, "added a page")
        return Plan(f"add a page to the end of {src.name}" + (f", save as {out.name}" if out != src else ""), text[:600], go)
    if act == "stamp":
        text = (a.get("text") or "").strip()
        if not text:
            raise FileError("stamp needs text, e.g. DRAFT or CONFIDENTIAL.")
        pages = _pages(a.get("pages"), total)
        def go():
            from fpdf import FPDF
            w = PdfWriter(clone_from=reader)
            for i in pages:
                pg = w.pages[i]
                wd, ht = float(pg.mediabox.width), float(pg.mediabox.height)
                ov = FPDF(unit="pt", format=(wd, ht)); ov.add_page()
                f = _font_path(bold=True)
                if f:
                    ov.add_font("stamp", "", f); ov.set_font("stamp", "", 44)
                else:
                    ov.set_font("helvetica", "B", 44)
                ov.set_text_color(200, 40, 40)
                tw = ov.get_string_width(text)
                with ov.rotation(30, wd / 2, ht / 2):
                    ov.text(wd / 2 - tw / 2, ht / 2 + 15, _clean(text, bool(f)))
                pg.merge_page(PdfReader(io.BytesIO(bytes(ov.output()))).pages[0])
            return write(w, f"stamped {text!r} on {len(pages)} page(s)")
        return Plan(f"stamp {text!r} on page(s) {', '.join(str(i + 1) for i in pages)} of {src.name}", "", go)
    if act in ("delete_pages", "keep_pages"):
        pages = _pages(a.get("pages"), total)
        keep = [i for i in range(total) if (i not in pages) == (act == "delete_pages")]
        if not keep:
            raise FileError("That would leave no pages.")
        def go():
            w = PdfWriter()
            for i in keep:
                w.add_page(reader.pages[i])
            return write(w, f"kept pages {', '.join(str(i + 1) for i in keep)}")
        return Plan(f"{'delete' if act == 'delete_pages' else 'keep only'} page(s) {', '.join(str(i + 1) for i in pages)} of {src.name}"
                    + (f", save as {out.name}" if out != src else ""), f"{total} → {len(keep)} page(s)", go)
    if act == "rotate":
        pages = _pages(a.get("pages"), total)
        deg = int(a.get("degrees") or 90)
        if deg % 90:
            raise FileError("degrees must be a multiple of 90.")
        def go():
            w = PdfWriter(clone_from=reader)
            for i in pages:
                w.pages[i].rotate(deg)
            return write(w, f"rotated {len(pages)} page(s) by {deg}°")
        return Plan(f"rotate page(s) {', '.join(str(i + 1) for i in pages)} of {src.name} by {deg}°", "", go)
    if act == "merge":
        other = find(a.get("other", ""))
        if not other or kind(other) != "pdf":
            raise FileError("merge needs other: the name of a second PDF in the workspace.")
        def go():
            w = PdfWriter(clone_from=reader)
            w.append(str(other))
            return write(w, f"appended {other.name}")
        return Plan(f"append {other.name} to {src.name}" + (f", save as {out.name}" if out != src else ""), "", go)
    raise FileError("action must be one of add_page, stamp, delete_pages, keep_pages, rotate, merge. "
                    "To change the words in a PDF use edit_file; to make a new one use write_file with a .pdf name.")


def match_images(spec: str) -> list[Path]:
    """One name, a comma list, or a pattern like milo-*.jpg."""
    import fnmatch
    imgs = [f for f in files() if kind(f) == "image"]
    out = []
    for part in [x.strip() for x in (spec or "").split(",") if x.strip()]:
        if any(c in part for c in "*?"):
            out += [f for f in imgs if fnmatch.fnmatch(f.name.lower(), part.lower())]
        else:
            f = find(part)
            if f and kind(f) == "image":
                out.append(f)
    if not out:
        # "the Milo photos", "my park pictures": match images whose names contain the meaningful words
        stop = {"the", "my", "all", "photo", "photos", "picture", "pictures", "image", "images", "pics", "from", "of", "and", "jpg", "png"}
        words = [w for w in re.findall(r"[a-z0-9]+", (spec or "").lower()) if len(w) >= 3 and w not in stop]
        out = [f for f in imgs if words and any(w in f.name.lower() for w in words)]
    return list(dict.fromkeys(out))


def _image_op(act: str, a: dict, W: int, H: int):
    """(description, function on a PIL image) for one action."""
    from PIL import Image, ImageDraw, ImageEnhance, ImageOps

    def num(k, d=None):
        v = a.get(k, d)
        return None if v in (None, "") else int(float(v))

    if act == "resize":
        w, h = num("width"), num("height")
        if not w and not h:
            raise FileError("resize needs width or height (pixels).")
        if w and h and not a.get("stretch"):
            r = min(w / W, h / H)
            w, h = round(W * r), round(H * r)
        elif w and not h:
            h = round(H * w / W)
        elif h and not w:
            w = round(W * h / H)
        return f"resize to {w}x{h}", lambda im: im.resize((w, h), Image.LANCZOS)
    if act == "crop":
        box = a.get("box")
        if isinstance(box, str):
            box = [int(x) for x in re.findall(r"-?\d+", box)]
        if not box or len(box) != 4:
            raise FileError("crop needs box: left,top,right,bottom in pixels (or use square).")
        return f"crop to {box}", lambda im: im.crop(tuple(box))
    if act == "square":
        def sq(im):
            side = min(im.size)
            l, t = (im.width - side) // 2, (im.height - side) // 2
            return im.crop((l, t, l + side, t + side))
        return "crop to a centred square", sq
    if act == "rotate":
        deg = num("degrees", 90)
        return f"rotate {deg}° clockwise", lambda im: im.rotate(-deg, expand=True)
    if act == "grayscale":
        return "convert to black and white", lambda im: ImageOps.grayscale(im)
    if act == "flip":
        return "mirror left to right", lambda im: ImageOps.mirror(im)
    if act == "enhance":
        def enh(im):
            from PIL import ImageStat
            im = ImageOps.autocontrast(im.convert("RGB"), cutoff=0.5, preserve_tone=True)   # same colours, fuller range
            mean = ImageStat.Stat(im.convert("L")).mean[0] / 255
            if mean < 0.45:                                    # lift a dark photo towards normal exposure
                g = max(0.5, min(1.0, __import__("math").log(0.48) / __import__("math").log(max(mean, 0.05))))
                im = im.point(lambda v: int(255 * (v / 255) ** g))
            im = ImageEnhance.Contrast(im).enhance(1.05)
            return ImageEnhance.Color(im).enhance(1.1)
        return "brighten and balance (auto contrast, a little more colour)", enh
    if act == "warm":
        def warm(im):
            r, g, b = im.convert("RGB").split()
            return Image.merge("RGB", (r.point(lambda v: min(255, int(v * 1.08))), g, b.point(lambda v: int(v * 0.92))))
        return "give a warmer tone", warm
    if act == "remove_location":
        return "remove the location and camera metadata", lambda im: im
    if act == "caption":
        text = (a.get("text") or "").strip()
        if not text:
            raise FileError("caption needs text.")
        def cap(im):
            im = im.convert("RGB")
            size = max(16, im.width // 28)
            font = _font(size, bold=True)
            lines = _wrap(ImageDraw.Draw(im), text, font, im.width - 2 * size)
            band = size // 2 + len(lines) * int(size * 1.35) + size // 2
            canvas = Image.new("RGB", (im.width, im.height + band), "#111111")
            canvas.paste(im, (0, 0))
            d = ImageDraw.Draw(canvas)
            y = im.height + size // 2
            for l in lines:
                d.text((size, y), l, font=font, fill="#ffffff"); y += int(size * 1.35)
            return canvas
        return f"add the caption {text!r} under the picture", cap
    if act == "convert":
        return "convert format", lambda im: im
    raise FileError("action must be one of enhance, square, remove_location, resize, crop, rotate, grayscale, warm, flip, caption, convert.")


def _save_image(res, out: Path, keep_meta: bytes | None) -> None:
    if out.suffix.lower() in (".jpg", ".jpeg") and res.mode not in ("RGB", "L"):
        res = res.convert("RGB")
    kw = {"quality": 92} if out.suffix.lower() in (".jpg", ".jpeg", ".webp") else {}
    if keep_meta:
        kw["exif"] = keep_meta
    res.save(out, **kw)


def _plan_image(a: dict) -> Plan:
    from PIL import Image
    srcs = match_images(a.get("name", ""))
    if not srcs:
        raise FileError(f"No image matching {a.get('name')!r}. Images: " + ", ".join(f.name for f in files() if kind(f) == "image"))
    acts = [x.strip().lower().replace(" ", "_") for x in str(a.get("action") or "").split(",") if x.strip()]
    if not acts:
        # small models sometimes leave the action out: infer it from the other arguments
        if a.get("width") or a.get("height"):
            acts = ["resize"]
        elif a.get("degrees"):
            acts = ["rotate"]
        elif a.get("box"):
            acts = ["crop"]
        elif a.get("text"):
            acts = ["caption"]
        elif a.get("output") and Path(a["output"]).suffix.lower() != srcs[0].suffix.lower():
            acts = ["convert"]
        else:
            raise FileError("Give an action: enhance, square, remove_location, resize, crop, rotate, grayscale, warm, flip, caption or convert.")
    single = len(srcs) == 1
    if a.get("output") and not single:
        raise FileError("output works for one image; with several, each is changed in place (old versions are kept).")
    outs = {src: _target(a["output"]) if a.get("output") else src for src in srcs}
    if any(kind(o) != "image" for o in outs.values()):
        raise FileError("output must be an image name (.png, .jpg, .webp).")
    if "convert" in acts and all(o == s for s, o in outs.items()):
        raise FileError("convert needs output with the new extension, e.g. photo.jpg.")
    with Image.open(srcs[0]) as im0:
        W, H = im0.size
    descs = [_image_op(act, a, W, H)[0] for act in acts]     # validates every action up front
    strip = "remove_location" in acts

    def go():
        done = []
        for src in srcs:
            out = outs[src]
            with Image.open(src) as im:
                im.load()
                meta = None
                if not strip:
                    ex = im.getexif()
                    meta = ex.tobytes() if ex else None
                res = im
                for act in acts:
                    res = _image_op(act, a, res.width, res.height)[1](res)
            _backup(out)
            _save_image(res, out, meta)
            done.append(f"{out.name} ({res.width}x{res.height})")
        tail = " Location removed." if strip else ""
        return f"Done: {', '.join(descs)} for {len(done)} image(s): {'; '.join(done)}.{tail} Previous versions kept."
    who = srcs[0].name + (f" ({W}x{H})" if single else "") if single else f"{len(srcs)} images: " + ", ".join(p.name for p in srcs)
    where = f" → {outs[srcs[0]].name}" if single and outs[srcs[0]] != srcs[0] else ""
    detail = ""
    if strip:
        with Image.open(srcs[0]) as im:
            m = photo_meta(im)
        detail = ("now: " + "; ".join(f"{k} {v}" for k, v in m.items())) if m else "no metadata found"
    return Plan(f"{', '.join(descs)}: {who}{where}", detail, go)


def _plan_make_image(a: dict) -> Plan:
    from PIL import Image, ImageDraw
    out = _target(a.get("name", ""))
    if kind(out) != "image":
        raise FileError("name must end in .png or .jpg")
    style = (a.get("style") or "card").strip()
    title = (a.get("title") or "").strip()
    text = (a.get("text") or "").strip()
    bg = _hex(a.get("color"), "#1f3a5f")
    W, H = int(a.get("width") or 1200), int(a.get("height") or 675)
    labels = a.get("labels") or []
    values = a.get("values") or []
    if isinstance(labels, str):
        labels = [x.strip() for x in labels.split(",") if x.strip()]
    if isinstance(values, str):
        values = [float(x) for x in re.findall(r"-?\d+(?:\.\d+)?", values)]
    if style == "chart" and (not labels or len(labels) != len(values)):
        raise FileError("A chart needs labels and values of the same length.")
    photos = match_images(a.get("photos") or "") if style == "collage" else []
    if style == "collage" and len(photos) < 2:
        raise FileError("A collage needs photos: two or more image names or a pattern like milo-*.jpg.")
    if style not in ("card", "chart", "collage"):
        raise FileError("style must be card (title and text), chart (bar chart) or collage (photos side by side).")

    def go():
        if style == "collage":
            n = len(photos)
            cols = n if n <= 3 else 2 if n == 4 else 3
            rows = (n + cols - 1) // cols
            cell, gap = 600, 16
            band = 90 if title else 0
            im = Image.new("RGB", (cols * cell + (cols + 1) * gap, rows * cell + (rows + 1) * gap + band), "#faf7f2")
            d = ImageDraw.Draw(im)
            if title:
                f = _font(44, bold=True)
                d.text((gap + 8, 22), title, font=f, fill="#2b2420")
            for i, p in enumerate(photos):
                with Image.open(p) as ph:
                    ph = ph.convert("RGB")
                    side = min(ph.size)
                    l, t = (ph.width - side) // 2, (ph.height - side) // 2
                    ph = ph.crop((l, t, l + side, t + side)).resize((cell, cell), Image.LANCZOS)
                r, c = divmod(i, cols)
                im.paste(ph, (gap + c * (cell + gap), band + gap + r * (cell + gap)))
            _backup(out)
            _save_image(im, out, None)
            return f"Done: made {out.name}, a collage of {n} photos ({im.width}x{im.height}); no location data in it."
        im = Image.new("RGB", (W, H), bg if style == "card" else "#ffffff")
        d = ImageDraw.Draw(im)
        pad = W // 14
        if style == "card":
            y = pad
            tf = _font(W // 16, bold=True)
            for l in _wrap(d, title, tf, W - 2 * pad):
                d.text((pad, y), l, font=tf, fill="#ffffff"); y += int(W / 16 * 1.25)
            y += W // 40
            bf = _font(W // 34)
            for l in _wrap(d, text, bf, W - 2 * pad):
                d.text((pad, y), l, font=bf, fill="#e8eef5"); y += int(W / 34 * 1.5)
        else:
            tf, lf = _font(W // 30, bold=True), _font(W // 50)
            d.text((pad, pad // 2), title, font=tf, fill="#1d2433")
            top, bottom = pad // 2 + W // 18, H - pad
            vmax = max(max(values), 1e-9)
            n = len(values)
            slot = (W - 2 * pad) / n
            for i, (lab, v) in enumerate(zip(labels, values)):
                x0 = pad + i * slot + slot * 0.18
                x1 = pad + (i + 1) * slot - slot * 0.18
                y0 = bottom - (bottom - top - W // 30) * (v / vmax)
                d.rectangle([x0, y0, x1, bottom], fill=bg)
                vs = f"{v:g}"
                d.text(((x0 + x1) / 2 - d.textlength(vs, font=lf) / 2, y0 - W // 40), vs, font=lf, fill="#1d2433")
                ls = str(lab)[:14]
                d.text(((x0 + x1) / 2 - d.textlength(ls, font=lf) / 2, bottom + W // 120), ls, font=lf, fill="#4a5568")
            d.line([pad, bottom, W - pad, bottom], fill="#9aa5b1", width=2)
        _backup(out)
        im.save(out)
        return f"Done: made {out.name} ({W}x{H} {style})."
    det = f"title: {title}\n" + (f"text: {text[:300]}" if style == "card" else
                                  "photos: " + ", ".join(p.name for p in photos) if style == "collage" else
                                  "bars: " + ", ".join(f"{l} {v:g}" for l, v in zip(labels, values)))
    size = "" if style == "collage" else f", {W}x{H}"
    return Plan(f"{'overwrite' if out.exists() else 'create'} the image {out.name} ({style}{size})", det, go)


ACTION_TOOLS = {"write_file", "edit_file", "pdf_pages", "edit_image", "make_image"}

LOOK_TOOL = {"type": "function", "function": {"name": "look_at_image", "description": (
    "Look at a photo or image in the workspace with the on-device vision model and answer a question about it: what it "
    "shows, whether it is too dark, which of several is best, a caption. To compare photos pass them all at once: a "
    "pattern like milo-*.jpg or a comma list (up to four are looked at together)."),
    "parameters": {"type": "object", "properties": {
        "name": {"type": "string"}, "question": {"type": "string", "description": "what to look for"}},
        "required": ["name"]}}}

TOOL_DEFS = [
    {"type": "function", "function": {"name": "write_file", "description": (
        "Create or overwrite a file in the user's workspace folder. A .txt/.md name writes text; a .pdf name lays the "
        "text out as a PDF (# headings and - bullets work). The user approves before anything is written."),
        "parameters": {"type": "object", "properties": {
            "name": {"type": "string", "description": "file name, e.g. reply-to-landlord.txt or summary.pdf"},
            "content": {"type": "string", "description": "the full text of the file"},
            "title": {"type": "string", "description": "optional title for a PDF"}},
            "required": ["name", "content"]}}},
    {"type": "function", "function": {"name": "edit_file", "description": (
        "Change the words in an existing text or PDF file (.txt, .md, .pdf): replace an exact passage (find → replace) "
        "or append text at the end. Use this for any correction of wording or numbers. The user approves the change."),
        "parameters": {"type": "object", "properties": {
            "name": {"type": "string"}, "find": {"type": "string", "description": "exact text to replace"},
            "replace": {"type": "string"}, "append": {"type": "string", "description": "text to add at the end instead"}},
            "required": ["name"]}}},
    {"type": "function", "function": {"name": "pdf_pages", "description": (
        "Work on a PDF's pages, not its words: add_page (a new page of text at the end), stamp (a big diagonal label "
        "such as DRAFT or CONFIDENTIAL), delete_pages, keep_pages, rotate, merge (append another PDF). It never changes "
        "existing words: to change or correct text in a PDF use edit_file. Optional output saves a copy."),
        "parameters": {"type": "object", "properties": {
            "name": {"type": "string"}, "action": {"type": "string", "enum": ["add_page", "stamp", "delete_pages", "keep_pages", "rotate", "merge"]},
            "text": {"type": "string"}, "title": {"type": "string"}, "pages": {"type": "string", "description": "e.g. 1,3-4; default all"},
            "degrees": {"type": "integer"}, "other": {"type": "string", "description": "second PDF for merge"},
            "output": {"type": "string"}}, "required": ["name", "action"]}}},
    {"type": "function", "function": {"name": "edit_image", "description": (
        "Edit photos and images on the user's own devices. name is one file, a comma list, or a pattern like "
        "milo-*.jpg for several at once. action is one or more of: enhance (brighten and balance a dark photo), square "
        "(centred square crop), remove_location (strip GPS and camera data before sharing), resize, crop, rotate, "
        "grayscale, warm, flip, caption (text under the picture), convert (new format via output). Combine with "
        "commas, e.g. enhance,square,remove_location. Optional output saves a copy (one image only)."),
        "parameters": {"type": "object", "properties": {
            "name": {"type": "string"}, "action": {"type": "string", "description": "e.g. enhance or enhance,square,remove_location"},
            "width": {"type": "integer", "description": "pixels; proportions are kept"}, "height": {"type": "integer"},
            "box": {"type": "string", "description": "crop box left,top,right,bottom"},
            "degrees": {"type": "integer"}, "text": {"type": "string"}, "output": {"type": "string"}},
            "required": ["name", "action"]}}},
    {"type": "function", "function": {"name": "make_image", "description": (
        "Make a new image: style card (a title and text on a coloured background, e.g. an invite), chart (a bar chart "
        "from labels and values) or collage (photos side by side; photos is a comma list or a pattern like milo-*.jpg). "
        "The user approves before it is saved."),
        "parameters": {"type": "object", "properties": {
            "name": {"type": "string", "description": "e.g. invite.png"}, "style": {"type": "string", "enum": ["card", "chart", "collage"]},
            "title": {"type": "string"}, "text": {"type": "string"},
            "labels": {"type": "array", "items": {"type": "string"}}, "values": {"type": "array", "items": {"type": "number"}},
            "photos": {"type": "string", "description": "for a collage"},
            "color": {"type": "string", "description": "hex colour, e.g. #1f3a5f"}},
            "required": ["name", "style", "title"]}}},
]
