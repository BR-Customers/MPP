# -*- coding: utf-8 -*-
"""Generate the in-app "How To" popup views.

WHY A GENERATOR AT ALL. The guide body is one multi-kilobyte HTML string inside
a view.json. Hand-editing that is how you get an unclosed tag that swallows the
rest of the page and is invisible in a diff. Authoring it here means the content
is readable, the helpers enforce a consistent shape, and the escaping is applied
once on the way out.

MPP has no general view generator - views are file-authored JSON - so this is
scoped to the How To popups and nothing else. Re-running it rewrites only the
views it owns.

    python tools/gen_howto_views.py            # write the views
    python tools/gen_howto_views.py --check    # verify, write nothing

THE TWO TRAPS, both silent and total:
  1. The text goes in props.source. props.markdown is an options OBJECT; a
     string there renders nothing at all.
  2. escapeHtml defaults to True. With HTML in the source and the default left
     alone the operator reads `<div style="...">` on screen. The two settings
     only mean anything together.

HTML here renders through a plain HTML pipeline, NOT the Perspective layout
engine: flexbox and <style> blocks are not dependable. Structured content is
built the way an HTML email is - nested tables, every style inline, literal hex
colours rather than var(--mpp-*), which is not guaranteed to resolve outside
Perspective's own styling.
"""

import io
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MPP_VIEWS = os.path.join(
    REPO, "ignition", "projects", "MPP",
    "com.inductiveautomation.perspective", "views", "BlueRidge")

# ---------------------------------------------------------------- palette ---
# Literal hex lifted from the plant-floor tokens in the Core stylesheet, so the
# guide reads as part of the app. Dark surface, light text - the plant floor is
# a dark theme, and a guide built on the usual light-background email palette
# would be unreadable here.
INK        = "#F0F3F8"   # --mpp-neutral-100, headings
BODY       = "#C9D2E0"   # --mpp-neutral-90,  body copy
MUTED      = "#9AA8BF"   # --mpp-neutral-80,  secondary
CARD       = "#172238"   # --mpp-neutral-30,  raised panel
ACCENT     = "#22A8CC"   # --mpp-accent-60,   step badge
ACCENT_INK = "#0B1220"   # --mpp-neutral-10,  text ON the accent badge
WARN_BG    = "#3A2E10"   # --mpp-cat-amber-bg
WARN_EDGE  = "#F4B343"   # --pf-status-warn-fg
INFO_BG    = "#093240"   # --mpp-accent-20
INFO_EDGE  = "#22A8CC"


def _step(n, title, body):
    """A numbered disc beside flowing text.

    A two-cell table row is the one layout that reliably puts a fixed-width
    badge next to wrapping text in this renderer."""
    return (
        '<table width="100%%" cellpadding="0" cellspacing="0" border="0" '
        'style="margin:0 0 14px 0;"><tr>'
        '<td width="46" valign="top">'
        '<div style="width:34px;height:34px;border-radius:17px;'
        'background-color:%s;color:%s;font-size:17px;font-weight:bold;'
        'text-align:center;line-height:34px;">%s</div></td>'
        '<td valign="top" style="padding-top:2px;">'
        '<div style="font-size:15px;font-weight:bold;color:%s;">%s</div>'
        '<div style="font-size:13.5px;color:%s;padding-top:3px;'
        'line-height:1.5;">%s</div>'
        '</td></tr></table>'
    ) % (ACCENT, ACCENT_INK, n, INK, title, BODY, body)


def _callout(bg, edge, heading, body):
    """A boxed aside. Colour carries the difference, not a louder heading."""
    return (
        '<table width="100%%" cellpadding="0" cellspacing="0" border="0" '
        'style="margin:4px 0 16px 0;"><tr>'
        '<td style="background-color:%s;border-left:5px solid %s;'
        'border-radius:4px;padding:12px 14px;">'
        '<div style="font-size:14px;font-weight:bold;color:%s;'
        'padding-bottom:4px;">%s</div>'
        '<div style="font-size:13.5px;color:%s;line-height:1.5;">%s</div>'
        '</td></tr></table>'
    ) % (bg, edge, INK, heading, BODY, body)


def _lead(text):
    return ('<div style="font-size:14.5px;color:%s;line-height:1.55;'
            'padding:0 0 16px 0;">%s</div>') % (BODY, text)


def _rule():
    return ('<div style="border-top:1px solid %s;margin:2px 0 16px 0;">'
            '</div>') % CARD


def _b(t):
    return '<span style="color:%s;font-weight:bold;">%s</span>' % (INK, t)


# ------------------------------------------------------------- die cast -----
# Written for the operator at the machine, not for whoever built the system.
# Order matches the screen: the die, then the three tabs left to right.
def diecast_source():
    parts = []
    parts.append(_lead(
        'Open a basket into each cavity, record what the die makes during your '
        'shift, then release the baskets when they are full.'))

    parts.append(_step(1, 'Check the die',
        'The %s box at the top names the tool mounted on this machine, and the '
        'cavity rows below come from it. If it is empty or names a different '
        'die, stop and tell a supervisor &ndash; do not work around it.'
        % _b('DIE')))

    parts.append(_step(2, 'Open a basket into each cavity',
        'On %s, each row is one cavity. Pick the %s for the cavity, then scan '
        'the %s from the basket into that row. Press %s to open every row you '
        'filled in. On a single-part die, fill the first row and press %s.'
        % (_b('Open Basket'), _b('Part'), _b('LTT Barcode'),
           _b('OPEN BASKETS'), _b('Copy part to empty rows'))))

    parts.append(_step(3, 'Record what the die made',
        'On %s, choose your %s and enter the shot count. Press %s, correct the '
        '%s figure on any row that needs it, and use %s to log scrap against a '
        'cavity. Press %s when the rows look right.'
        % (_b('Record Shift Output'), _b('Reporting shift'),
           _b('Compute / Preview'), _b('Good (pc)'), _b('Add scrap reason'),
           _b('SUBMIT SHIFT OUTPUT'))))

    parts.append(_step(4, 'Release the full baskets',
        'On %s, press %s on a basket that is full. It leaves the cavity, moves '
        'on to its next step, and frees the cavity for a new basket. %s only '
        'appears on an empty basket and discards it.'
        % (_b('Lot Release'), _b('Release'), _b('Void'))))

    parts.append(_rule())

    parts.append(_callout(WARN_BG, WARN_EDGE,
        'The shot count is for the whole die',
        'One machine cycle makes one part in every active cavity, so %s is the '
        'number of cycles &ndash; enter it once. The system splits it across '
        'the open cavities for you. Do not multiply it by the number of '
        'cavities.' % _b('Shots this entry')))

    parts.append(_callout(INFO_BG, INFO_EDGE,
        'If a basket goes over its count',
        'The row shows %s and submitting asks you to choose. %s tops the basket '
        'up to its limit, releases it, and asks you to scan a new LTT &ndash; '
        'the extra parts go into the new basket automatically. %s keeps '
        'everything in the one basket and carries on past the limit.'
        % (_b('Over basket headroom'), _b('Fill'), _b('Overfill'))))

    parts.append(_rule())

    parts.append(
        '<div style="font-size:14px;font-weight:bold;color:%s;'
        'padding-bottom:5px;">You do not have to type</div>'
        '<div style="font-size:13.5px;color:%s;line-height:1.6;'
        'padding-bottom:14px;">'
        'The die, the list of cavities, how the shots split between them, or '
        'any of the totals down the right-hand side. All of that follows from '
        'the mounted tool and the one shot count you enter.'
        '</div>' % (INK, BODY))

    parts.append(
        '<div style="font-size:14px;font-weight:bold;color:%s;'
        'padding-bottom:5px;">What happens next</div>'
        '<div style="font-size:13.5px;color:%s;line-height:1.6;">'
        'A released basket carries its LTT to the next step on its route, and '
        'the shift figures on the right update straight away.'
        '</div>' % (INK, MUTED))

    return ''.join(parts)


GUIDES = [
    {
        "dir": os.path.join(MPP_VIEWS, "Components", "Popups", "DieCastHowTo"),
        "source": diecast_source,
        "defaultSize": {"width": 720, "height": 620},
    },
]


# ------------------------------------------------------------- emitting -----
# Designer rewrites < > & = ' as six-character unicode escapes inside JSON
# string values on its next save. Pre-escaping the same way means that save
# produces no diff, instead of rewriting the whole multi-kilobyte string.
_DESIGNER_ESCAPES = {"<": "u003c", ">": "u003e", "&": "u0026",
                     "=": "u003d", "'": "u0027"}


def _designer_escape(dumped):
    """Apply Designer's escaping to an already json.dumps-ed string literal."""
    out = dumped
    for ch, esc in _DESIGNER_ESCAPES.items():
        out = out.replace(ch, "\\" + esc)
    return out


def build_view(source_html, default_size):
    """The popup view. One markdown component filling the modal.

    props.source carries the text; props.markdown is the OPTIONS object and
    must set escapeHtml false or the operator reads raw tags."""
    return {
        "custom": {},
        "params": {},
        "propConfig": {},
        "props": {"defaultSize": default_size},
        "root": {
            "type": "ia.container.flex",
            "meta": {"name": "root"},
            "props": {
                "direction": "column",
                "style": {"classes": "modal", "padding": "14px 16px"},
            },
            "children": [
                {
                    "type": "ia.display.markdown",
                    "meta": {"name": "Guide"},
                    "position": {"basis": "0px", "grow": 1},
                    "props": {
                        "source": source_html,
                        "markdown": {"escapeHtml": False},
                        "sectionSpacing": 8,
                        "style": {"fontSize": 13, "overflow": "auto"},
                    },
                }
            ],
        },
    }


RESOURCE_JSON = {
    "scope": "G",
    "version": 1,
    "restricted": False,
    "overridable": True,
    "files": ["view.json"],
    "attributes": {
        "lastModification": {"actor": "claude", "timestamp": "2026-08-28T12:00:00Z"}
    },
}


# ------------------------------------------------------------- verifying ----
# Every one of these fails SILENTLY and TOTALLY in the running client, which is
# why they are worth a check rather than a look.
def verify(view, path):
    errs = []
    md = None

    def walk(o):
        nonlocal md
        if isinstance(o, dict):
            if o.get("type") == "ia.display.markdown":
                md = o
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    walk(view)
    if md is None:
        errs.append("no ia.display.markdown component")
        return errs

    props = md.get("props") or {}
    src = props.get("source")

    # empty source renders as a blank panel, with no error anywhere
    if not src or not str(src).strip():
        errs.append("props.source is empty")
        return errs

    # a string in props.markdown is the classic mix-up and renders nothing
    if isinstance(props.get("markdown"), str):
        errs.append("props.markdown is a string; the text belongs in props.source")

    # HTML with escapeHtml left true prints the tags to the operator
    if "<" in src:
        opts = props.get("markdown")
        if not isinstance(opts, dict) or opts.get("escapeHtml") is not False:
            errs.append("source contains HTML but markdown.escapeHtml is not false")

    # one unclosed tag swallows the rest of the guide and is invisible in a diff
    for tag in ("table", "tr", "td", "div", "span"):
        o = len(re.findall(r"<%s[\s>]" % tag, src))
        c = len(re.findall(r"</%s>" % tag, src))
        if o != c:
            errs.append("tag <%s> unbalanced: %d open, %d close" % (tag, o, c))

    return errs


def main():
    check_only = "--check" in sys.argv
    failed = False

    for g in GUIDES:
        src = g["source"]()
        view = build_view(src, g["defaultSize"])
        name = os.path.basename(g["dir"])

        errs = verify(view, g["dir"])
        if errs:
            failed = True
            print("FAIL %s" % name)
            for e in errs:
                print("       %s" % e)
            continue
        print("ok   %-16s source %5d chars" % (name, len(src)))

        if check_only:
            continue

        os.makedirs(g["dir"], exist_ok=True)
        body = _designer_escape(json.dumps(view, indent=2, sort_keys=True,
                                           ensure_ascii=False))
        io.open(os.path.join(g["dir"], "view.json"), "w",
                encoding="utf-8", newline="\r\n").write(body + "\n")
        io.open(os.path.join(g["dir"], "resource.json"), "w",
                encoding="utf-8", newline="\r\n").write(
            json.dumps(RESOURCE_JSON, indent=2) + "\n")

    disk, n_paths = verify_on_disk()
    if disk:
        failed = True
        print("FAIL cross-file")
        for e in disk:
            print("       %s" % e)
    else:
        print("ok   cross-file      resource.json present; %d openPopup "
              "viewPath(s) resolve" % n_paths)

    if failed:
        sys.exit(1)
    print("--check: verified only, nothing written" if check_only else "written")




# ------------------------------------------------- cross-file verification --
# These two need the written files plus the screens that open them, so they run
# separately from verify() which only sees the view dict.
def verify_on_disk():
    """Checks that only make sense against the repo as a whole.

    Scripts are read from the PARSED json, not the raw text, so the six-char
    unicode escapes Designer writes are already decoded and the quote is just a
    quote. Regexing the raw file for an escaped quote is possible but the
    pattern is unreadable and easy to get wrong."""
    errs = []
    proj = os.path.join(REPO, "ignition", "projects", "MPP",
                        "com.inductiveautomation.perspective", "views")
    # A Perspective project INHERITS its parent's views, so a viewPath that is
    # absent from MPP may still resolve from Core at runtime. Resolving against
    # MPP alone reports inherited popups as broken - ConfirmDestructive lives
    # in Core and is used from MPP.
    search = _view_roots("MPP")

    for g in GUIDES:
        name = os.path.basename(g["dir"])
        if not os.path.exists(os.path.join(g["dir"], "view.json")):
            errs.append("%s: view.json missing" % name)
            continue
        # a view folder with no resource.json is invisible to the gateway and
        # never renders, with no error anywhere
        if not os.path.exists(os.path.join(g["dir"], "resource.json")):
            errs.append("%s: resource.json missing - the gateway will not "
                        "see this view" % name)

    # Every openPopup viewPath must name a view that exists. A wrong path opens
    # nothing at all, silently, which is why this is worth checking.
    # Popup calls in this project use either quote style, so accept both -
    # a pattern that only matched one style would silently validate a fraction
    # of the call sites and look like it had checked them all.
    pat = re.compile(r"""openPopup\(\s*[^,]+,\s*(?:'([^']+)'|"([^"]+)")""")
    checked = 0
    for root, _dirs, files in os.walk(proj):
        if "view.json" not in files:
            continue
        try:
            view = json.load(io.open(os.path.join(root, "view.json"),
                                     encoding="utf-8"))
        except ValueError as e:
            errs.append("%s: view.json does not parse (%s)"
                        % (os.path.relpath(root, proj), e))
            continue

        scripts = []

        def collect(o):
            if isinstance(o, dict):
                s = o.get("script")
                if isinstance(s, str):
                    scripts.append(s)
                for v in o.values():
                    collect(v)
            elif isinstance(o, list):
                for v in o:
                    collect(v)

        collect(view)
        for s in scripts:
            for m in pat.finditer(s):
                vpath = m.group(1) or m.group(2)
                if not vpath.startswith("BlueRidge/"):
                    continue
                checked += 1
                if not any(os.path.exists(os.path.join(r, *vpath.split("/"),
                                                       "view.json"))
                           for r in search):
                    errs.append("%s: openPopup targets '%s', which does not "
                                "exist in MPP or any parent project"
                                % (os.path.relpath(root, proj), vpath))
    return errs, checked


def _view_roots(project):
    """The view directories a project can resolve a viewPath from: its own,
    then each ancestor named by project.json's "parent"."""
    roots = []
    seen = set()
    name = project
    while name and name not in seen:
        seen.add(name)
        base = os.path.join(REPO, "ignition", "projects", name)
        vdir = os.path.join(base, "com.inductiveautomation.perspective", "views")
        if os.path.isdir(vdir):
            roots.append(vdir)
        try:
            meta = json.load(io.open(os.path.join(base, "project.json"),
                                     encoding="utf-8"))
        except (IOError, ValueError):
            break
        name = meta.get("parent")
    return roots
if __name__ == "__main__":
    main()
