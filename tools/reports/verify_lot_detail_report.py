"""Parse an Ignition report data.bin and describe its structure.

The report binary is generated, never hand-edited (see README.md). This module is
both the extractor that bootstrapped the source files and the structural test used
after every regeneration.
"""
import base64, os, re, struct, sys

SKILL_TOOLS = os.path.join(os.path.expanduser("~"), ".claude", "skills",
                           "ignition-reporting", "tools")
sys.path.insert(0, SKILL_TOOLS)

from ignition_report_codec import parse          # noqa: E402
import ignition_tree_codec as tc                 # noqa: E402

REPORT_BIN = os.path.join("ignition", "projects", "MPP",
                          "com.inductiveautomation.reporting", "reports",
                          "Lot Detail", "data.bin")


def _sid(st, i):
    v = st.get(i)
    return v if v is not None else "<%s>" % i


def _mname(st, e):
    for (nid, ct, raw) in e.attrs:
        if _sid(st, nid) == "m" and ct == tc.CODEC_STR and len(raw) == 4:
            return _sid(st, struct.unpack(">i", raw)[0])
    return None


def _body(st, e):
    if e.body is not None and len(e.body) == 4:
        return _sid(st, struct.unpack(">i", e.body)[0])
    return None


def _calls(st, e):
    out = {}
    for c in e.children:
        n = _mname(st, c)
        if n:
            out.setdefault(n, c)
    return out


def _subquery(st, e):
    """Describe a SubQuery element: key, tokens, sql, children."""
    k = _calls(st, e)
    key = None
    for c in k.get("setDataKey", e).children:
        key = _body(st, c) or key
    tokens, sql = [], None
    qc = k.get("setQueryConfig")
    if qc is not None:
        for cfg in qc.children:
            for s in cfg.children:
                sn = _mname(st, s)
                if sn == "setExpressions":
                    for lst in s.children:
                        for t in lst.children:
                            tokens.append(_body(st, t))
                elif sn == "setQuery":
                    for t in s.children:
                        sql = _body(st, t)
    children = []
    ch = k.get("setChildren")
    if ch is not None:
        for lst in ch.children:
            for sub in lst.children:
                if _calls(st, sub).get("setDataKey") is not None:
                    children.append(_subquery(st, sub))
    return {"key": key, "tokens": tokens, "sql": sql, "children": children}


def describe(path):
    """-> {title, parameters, sources, layout_xml}. sources are nested dicts."""
    d = parse(open(path, "rb").read())
    st = d["strings"]
    root = tc.parse_tree(d["element_tree_bytes"])

    sources, params, title, layout = [], [], None, None

    def walk(e):
        k = _calls(st, e)
        if "setRootQuery" in k:
            for sub in k["setRootQuery"].children:
                sources.append(_subquery(st, sub))
        for c in e.children:
            walk(c)

    walk(root)

    for i, s in sorted(st.items()):
        if not isinstance(s, str):
            continue
        t = s.strip()
        if len(t) > 400 and re.match(r"^[A-Za-z0-9+/=\s]+$", t):
            layout = base64.b64decode(t).decode("utf-8")

    # title + parameters read straight off the tree
    def walk2(e):
        k = _calls(st, e)
        if "setTitle" in k:
            for c in k["setTitle"].children:
                v = _body(st, c)
                if v:
                    walk2.title = v
        if "setName" in k and "setType" in k:
            nm = dv = None
            for c in k["setName"].children:
                nm = _body(st, c) or nm
            for c in k.get("setDefaultValue", k["setName"]).children:
                dv = _body(st, c) or dv
            if nm:
                params.append((nm, dv))
        for c in e.children:
            walk2(c)

    walk2.title = None
    walk2(root)
    title = walk2.title

    return {"title": title, "parameters": params, "sources": sources,
            "layout_xml": layout}


def _flatten(sources, depth=0, out=None):
    out = [] if out is None else out
    for s in sources:
        out.append((depth, s["key"], tuple(s["tokens"])))
        _flatten(s["children"], depth + 1, out)
    return out


def main(path=REPORT_BIN):
    info = describe(path)
    print("title      :", info["title"])
    print("parameters :", info["parameters"])
    print("layout     : %d chars" % len(info["layout_xml"] or ""))
    print("data sources:")
    for depth, key, toks in _flatten(info["sources"]):
        print("   %s%-22s tokens=%s" % ("    " * depth, key, list(toks)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else REPORT_BIN))
