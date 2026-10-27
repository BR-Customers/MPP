"""Sanitize a PDF saved from the gateway (the Super-lot report) for the sales kit.

Usage:
  python -I sanitize_pdf.py --in <raw.pdf> --out <clean.pdf> [--png <page1.png>]
                            [--cover "x0,y0,x1,y1=Replacement text"]...

Every text line whose text changes under the screens' rules (../substitutions.json + the date rule,
imported from sanitize.py) is redacted and rewritten in place: same origin, same size, Helvetica
(bold when the original font was bold). A --cover region (PDF points, origin top-left) is painted
white and the replacement written inside it -- for a logo or a vector header whose text is not a
text span. The metadata is replaced (title "Super-lot report", everything else empty, XMP removed).
A subset font whose name holds a banned term is a problem. The cleaned PDF's extracted text then
goes through check_terms.py with the full rules (dates included). Exit 0 only with no problem.
--png renders page 1 at 2x for the deck.
"""
import argparse, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
KIT_TOOLS = os.path.join(HERE, "..")
sys.path.insert(0, HERE)
sys.path.insert(0, KIT_TOOLS)
import pymupdf                       # noqa: E402
from sanitize import sub             # noqa: E402  (same rules as the screens)
from check_terms import load_patterns  # noqa: E402

METADATA = {"title": "Super-lot report", "author": "", "subject": "", "keywords": "", "creator": "",
            "producer": "", "creationDate": "", "modDate": "", "trapped": ""}


def font_problems(fonts):
    """fonts: page.get_fonts() tuples (xref, ext, type, basefont, name, encoding)."""
    pats = load_patterns(terms_only=True)
    out = []
    for f in fonts:
        base = f[3].split("+", 1)[-1]
        if any(p.search(base) for p in pats):
            out.append("font " + f[3])
    return out


def rewrite_lines(page):
    """Redact and rewrite every line whose text the rules change. Returns the number rewritten."""
    todo = []
    for block in page.get_text("dict")["blocks"]:
        for line in block.get("lines", []):
            spans = [s for s in line["spans"] if s["text"]]
            if not spans:
                continue
            text = "".join(s["text"] for s in spans)
            new = sub(text)
            if new != text:
                first = spans[0]
                bold = "bold" in first["font"].lower()
                todo.append((pymupdf.Rect(line["bbox"]), first["origin"], first["size"], new.strip(), bold, first["color"]))
    for rect, *_ in todo:
        page.add_redact_annot(rect, fill=(1, 1, 1))
    if todo:
        page.apply_redactions(images=pymupdf.PDF_REDACT_IMAGE_NONE)
    for rect, origin, size, new, bold, color in todo:
        rgb = tuple(((color >> s) & 255) / 255 for s in (16, 8, 0))
        page.insert_text(origin, new, fontsize=size, fontname="hebo" if bold else "helv", color=rgb)
    return len(todo)


def cover(page, spec):
    box, _, text = spec.partition("=")
    r = pymupdf.Rect(*[float(v) for v in box.split(",")])
    page.add_redact_annot(r, fill=(1, 1, 1))
    page.apply_redactions(images=pymupdf.PDF_REDACT_IMAGE_PIXELS, graphics=pymupdf.PDF_REDACT_LINE_ART_REMOVE_IF_TOUCHED)
    page.draw_rect(r, color=None, fill=(1, 1, 1))
    if text:
        size = min(11.0, max(6.0, r.height * 0.5))
        page.insert_text((r.x0 + 2, r.y0 + (r.height + size) / 2 - 1), text, fontsize=size, fontname="helv")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--png")
    ap.add_argument("--cover", action="append", default=[])
    a = ap.parse_args()

    doc = pymupdf.open(a.src)
    problems, rewritten = [], 0
    for page in doc:
        problems += font_problems(page.get_fonts())
        rewritten += rewrite_lines(page)
    for spec in a.cover:
        cover(doc[0], spec)
    doc.set_metadata(METADATA)
    doc.del_xml_metadata()
    doc.save(a.out, garbage=4, deflate=True)
    doc.close()

    with pymupdf.open(a.out) as clean:
        text = "\n".join(p.get_text() for p in clean)
        if a.png:
            clean[0].get_pixmap(matrix=pymupdf.Matrix(2, 2)).save(a.png)
    with tempfile.TemporaryDirectory() as tmp:
        open(os.path.join(tmp, "pdf_text.txt"), "w", encoding="utf-8").write(text)
        g = subprocess.run([sys.executable, "-I", os.path.join(KIT_TOOLS, "check_terms.py"), tmp], capture_output=True, text=True)
    if g.returncode != 0:
        problems.append("terms left in the PDF text:\n" + g.stdout)
    for p in problems:
        print("PROBLEM", p)
    print(f"sanitize_pdf: {rewritten} line(s) rewritten, {len(a.cover)} region(s) covered, {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
