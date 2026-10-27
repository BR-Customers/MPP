"""Grep a sales-kit folder for terms that must not leave Blue Ridge.

Usage: python -I check_terms.py <folder> [--terms-only] [--skip-prefix <line prefix>]

Scans every text file, and the XML inside every .pptx / .docx / .zip, against banned_terms.txt
(one case-insensitive regex per line, '#' comments) plus ISO dates and month-name years.
Prints 'path:line: term' per hit. Exit 0 when clean, 1 otherwise.
"""
import os, re, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKIP_DIRS = {"node_modules", "render", ".git", "__pycache__"}
ZIP_EXTS = {".pptx", ".docx", ".xlsx", ".zip"}
BINARY_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".woff", ".woff2", ".ttf"}
MONTHS = "january|february|march|april|may|june|july|august|september|october|november|december"


def load_patterns(terms_only=False):
    pats = []
    with open(os.path.join(HERE, "banned_terms.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                pats.append(re.compile(line, re.IGNORECASE))
    if not terms_only:   # dates matter in sales material, not in a database's audit columns
        pats.append(re.compile(r"\b20\d\d-\d\d-\d\d(?!\d)"))   # also ISO timestamps (2026-10-27T08:32)
        pats.append(re.compile(rf"\b({MONTHS})\s+20\d\d\b", re.IGNORECASE))
    return pats


SKIP_PREFIXES = []


def scan_text(label, text, pats, hits):
    for n, line in enumerate(text.splitlines(), 1):
        if any(line.startswith(p) for p in SKIP_PREFIXES):
            continue
        for p in pats:
            m = p.search(line)
            if m:
                hits.append(f"{label}:{n}: {m.group(0)}")


def main(folder, terms_only=False):
    pats = load_patterns(terms_only)
    hits = []
    term_pats = load_patterns(True)   # Office file timestamps (docProps/core.xml) are not content
    for root, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            if name.startswith("~$"):   # Office lock file left by an open (or crashed) editor
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, folder)
            ext = os.path.splitext(name)[1].lower()
            if ext in ZIP_EXTS:
                with zipfile.ZipFile(path) as z:
                    for member in z.namelist():
                        if member.endswith((".xml", ".rels", ".txt")):
                            scan_text(f"{rel}!{member}", z.read(member).decode("utf-8", "replace"),
                                      term_pats if member == "docProps/core.xml" else pats, hits)
            elif ext not in BINARY_EXTS:
                with open(path, encoding="utf-8", errors="replace") as f:
                    scan_text(rel, f.read(), pats, hits)
    for h in hits:
        print(h)
    print(f"{len(hits)} hit(s)")
    return 1 if hits else 0


if __name__ == "__main__":
    args = sys.argv[1:]
    # --skip-prefix P (repeatable): ignore lines starting with P, e.g. a database column that holds
    # functional configuration rather than displayed text (the icon-library path column).
    while "--skip-prefix" in args:
        i = args.index("--skip-prefix")
        SKIP_PREFIXES.append(args[i + 1])
        del args[i:i + 2]
    terms_only = "--terms-only" in args
    args = [a for a in args if a != "--terms-only"]
    sys.exit(main(args[0], terms_only))
