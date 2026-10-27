"""Sanitize raw screen captures for the sales kit and render the deck PNGs from them.

Usage:
  python -I sanitize.py --raw <CAP>/raw --out-screens <KIT>/deck-build/screens --out-captures <KIT>/demo-build/captures [--no-render]

Input (written by capture.js): <name>.json = {w, h, route, html} per step, and bundle.css.
Applies ../substitutions.json to every text node, to attribute values (except structural ones:
class, id, style, data-component*, href, src) and to CSS content:"..." strings. Writes the
sanitized <name>.json and bundle.css to --out-captures, and renders <name>.png into --out-screens
by loading the sanitized page in headless Chrome at its captured viewport.
Exits non-zero if any output still references a gateway (localhost / http(s) URL other than the
SVG namespace) or if check_terms.py finds a customer term in it.
"""
import argparse, html, json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
KIT_TOOLS = os.path.join(HERE, "..")
CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
STRUCTURAL = re.compile(r"^(class|id|style|href|src|xlink:href|data-component.*)$", re.I)
TAG_SPLIT = re.compile(r"(<[^>]*>)")
ATTR = re.compile(r"""(\s[\w:.-]+)=("[^"]*"|'[^']*')""")
CSS_CONTENT = re.compile(r'(content\s*:\s*")([^"]*)(")')
BAD_URL = re.compile(r"localhost|https?://(?!www\.w3\.org/)", re.I)

rules = [(re.compile(p), r) for p, r in json.load(open(os.path.join(KIT_TOOLS, "substitutions.json"), encoding="utf-8"))["rules"]]


def sub(text):
    for p, r in rules:
        text = p.sub(r, text)
    return text


def sub_escaped(fragment, quote=False):
    """Apply the rules to HTML-escaped text; leave it byte-identical when nothing matches."""
    plain = html.unescape(fragment)
    new = sub(plain)
    return fragment if new == plain else html.escape(new, quote=quote)


# The project's own name appears in style-class names (psc-MPP/..., psc-mpp-...) and icon paths.
# Those are identifiers, not text: rename the token the same way in class attributes and in the
# CSS so every selector still matches (MPP -> APP, mpp -> app, Mpp -> App).
PROJECT_TOKEN = re.compile(r"(?<![A-Za-z0-9])(MPP|mpp|Mpp)(?![A-Za-z0-9])")


def rename_ident(text):
    return PROJECT_TOKEN.sub(lambda m: {"MPP": "APP", "mpp": "app", "Mpp": "App"}[m.group(1)], text)


def sanitize_tag(tag):
    def attr(m):
        name, val = m.group(1), m.group(2)
        if name.strip().lower() in ("class", "style", "id"):   # identifiers and CSS variables, renamed like the bundle
            return f"{name}={rename_ident(val)}"
        if STRUCTURAL.match(name.strip()):
            return m.group(0)
        q, inner = val[0], val[1:-1]
        return f"{name}={q}{sub_escaped(inner, quote=True)}{q}"
    return ATTR.sub(attr, tag)


# Perspective client chrome, not the application: the gateway-connection banner, the session
# panel (gateway host name, session id, project timestamps), the app bar, the trial notice and the
# notification area. Dropped whole so none of it reaches the kit.
CHROME_CLASSES = ["connection-banner", "app-modal-wrapper", "app-bar", "action-panel-overlay", "notification-wrapper"]
DIV_TAG = re.compile(r"<(/?)div\b[^>]*>", re.I)


def drop_divs_with_class(page, cls):
    opener = re.compile(r'<div\b[^>]*\bclass="(?:[^"]*\s)?' + re.escape(cls) + r'(?:\s[^"]*)?"[^>]*>', re.I)
    while True:
        m = opener.search(page)
        if not m:
            return page
        depth, end = 0, None
        for t in DIV_TAG.finditer(page, m.start()):
            depth += -1 if t.group(1) else 1
            if depth == 0:
                end = t.end()
                break
        if end is None:
            raise SystemExit("unbalanced <div> after class " + cls)
        page = page[:m.start()] + page[end:]


def sanitize_html(page):
    for cls in CHROME_CLASSES:
        page = drop_divs_with_class(page, cls)
    parts = TAG_SPLIT.split(page)
    return "".join(sanitize_tag(p) if p.startswith("<") else sub_escaped(p) for p in parts)


CSS_COMMENT = re.compile(r"/\*.*?\*/", re.S)


def sanitize_css(css):
    css = CSS_COMMENT.sub("", css)   # developer notes (dates, names) - never needed to render
    css = CSS_CONTENT.sub(lambda m: m.group(1) + sub(m.group(2)) + m.group(3), css)
    return rename_ident(css)


def render(page_html, css, w, h, png):
    with tempfile.TemporaryDirectory() as tmp:
        doc = page_html.replace("</head>", "<style>" + css + "</style></head>", 1) if "</head>" in page_html \
            else "<!DOCTYPE html><html><head><style>" + css + "</style></head><body>" + page_html + "</body></html>"
        if not doc.lstrip().lower().startswith("<!doctype"):
            doc = "<!DOCTYPE html>" + doc
        src = os.path.join(tmp, "page.html")
        open(src, "w", encoding="utf-8").write(doc)
        shot = os.path.join(tempfile.gettempdir(), "kit-sanitize-shot.png")
        if os.path.exists(shot):
            os.remove(shot)
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run",
                        "--user-data-dir=" + os.path.join(tempfile.gettempdir(), "kit-sanitize-profile"),
                        f"--window-size={w},{h}", "--virtual-time-budget=3000", "--screenshot=" + shot,
                        "file:///" + src.replace("\\", "/")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
        if not os.path.exists(shot):
            raise SystemExit("render failed for " + png)
        shutil.copy(shot, png)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--out-screens", required=True)
    ap.add_argument("--out-captures", required=True)
    ap.add_argument("--no-render", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out_screens, exist_ok=True)
    os.makedirs(a.out_captures, exist_ok=True)

    css = sanitize_css(open(os.path.join(a.raw, "bundle.css"), encoding="utf-8").read())
    open(os.path.join(a.out_captures, "bundle.css"), "w", encoding="utf-8").write(css)
    problems = []
    if BAD_URL.search(css):
        problems.append("bundle.css: gateway reference " + BAD_URL.search(css).group(0))
    names = sorted(f[:-5] for f in os.listdir(a.raw) if f.endswith(".json"))
    for name in names:
        cap = json.load(open(os.path.join(a.raw, name + ".json"), encoding="utf-8"))
        cap["html"] = sanitize_html(cap["html"])
        m = BAD_URL.search(cap["html"])
        if m:
            problems.append(f"{name}: gateway reference near '{cap['html'][max(0, m.start() - 40):m.end() + 40]}'")
        json.dump(cap, open(os.path.join(a.out_captures, name + ".json"), "w", encoding="utf-8"), ensure_ascii=False)
        if not a.no_render and not problems:
            render(cap["html"], css, cap["w"], cap["h"], os.path.join(a.out_screens, name + ".png"))
            print(name, "rendered")

    g = subprocess.run([sys.executable, "-I", os.path.join(KIT_TOOLS, "check_terms.py"), a.out_captures, "--terms-only"],
                       capture_output=True, text=True)
    if g.returncode != 0:
        problems.append("customer terms left:\n" + g.stdout)
    for p in problems:
        print("PROBLEM", p)
    print(f"sanitize: {len(names)} screen(s), {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
