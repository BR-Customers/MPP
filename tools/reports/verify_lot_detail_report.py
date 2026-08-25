"""Parse an Ignition report data.bin and describe its structure.

The report binary is generated, never hand-edited (see README.md). This module is
both the extractor that bootstrapped the source files and the structural test used
after every regeneration.
"""
import base64, hashlib, os, re, struct, sys

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
            nm = tp = dv = None
            for c in k["setName"].children:
                nm = _body(st, c) or nm
            for c in k["setType"].children:
                tp = _body(st, c) or tp
            for c in k.get("setDefaultValue", k["setName"]).children:
                dv = _body(st, c) or dv
            if nm:
                params.append((nm, tp, dv))
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
        out.append((depth, s["key"], tuple(s["tokens"]), s["sql"]))
        _flatten(s["children"], depth + 1, out)
    return out


def _sql_fingerprint(sql):
    """Stable one-line proxy for SQL text so a human diff of two `main()` runs
    also catches SQL drift, without dumping the whole (often multi-line) query."""
    if sql is None:
        return "sql=<none>"
    digest = hashlib.sha256(sql.encode("utf-8")).hexdigest()[:12]
    return "sql=%s(%dch)" % (digest, len(sql))


def _compare_sources(sa, sb, path):
    """Recursively diff two lists of data-source dicts (key/tokens/sql/children).

    Matches siblings by `key` (not position) so a single added/removed source
    -- the intentionally-dropped `Genealogy` source being the known case -- shows
    up as exactly one difference instead of cascading a positional shift through
    every sibling after it.
    """
    diffs = []
    ka = [s["key"] for s in sa]
    kb = [s["key"] for s in sb]
    set_a, set_b = set(ka), set(kb)
    for k in ka:
        if k not in set_b:
            diffs.append("%s: source key %r present only in A" % (path or "<root>", k))
    for k in kb:
        if k not in set_a:
            diffs.append("%s: source key %r present only in B" % (path or "<root>", k))
    common_a = [k for k in ka if k in set_b]
    common_b = [k for k in kb if k in set_a]
    if common_a != common_b:
        diffs.append("%s: source order differs: %r != %r" % (path or "<root>", common_a, common_b))
    map_b = {s["key"]: s for s in sb}
    for A in sa:
        B = map_b.get(A["key"])
        if B is None:
            continue
        loc = "%s[key=%s]" % (path, A["key"])
        if tuple(A["tokens"]) != tuple(B["tokens"]):
            diffs.append("%s tokens: %r != %r" % (loc, A["tokens"], B["tokens"]))
        if A["sql"] != B["sql"]:
            diffs.append("%s sql differs (A %s vs B %s)" % (
                loc, _sql_fingerprint(A["sql"]), _sql_fingerprint(B["sql"])))
        diffs.extend(_compare_sources(A["children"], B["children"], loc + ".children"))
    return diffs


def compare(path_a, path_b):
    """Full structural equality between two built report binaries.

    Compares title, parameters (name, type AND default), and every data source's
    key, expression tokens, SQL TEXT and nesting -- recursively. Returns a list of
    human-readable difference strings; empty list means identical.

    This is the check that makes 'the generator reproduces the report' a verified
    claim rather than an asserted one.
    """
    a = describe(path_a)
    b = describe(path_b)
    diffs = []

    if a["title"] != b["title"]:
        diffs.append("title: %r != %r" % (a["title"], b["title"]))

    names_a = [p[0] for p in a["parameters"]]
    names_b = [p[0] for p in b["parameters"]]
    map_a = {p[0]: p for p in a["parameters"]}
    map_b = {p[0]: p for p in b["parameters"]}
    for name in names_a:
        if name not in map_b:
            diffs.append("parameter %r: present only in A" % name)
    for name in names_b:
        if name not in map_a:
            diffs.append("parameter %r: present only in B" % name)
    for name in names_a:
        if name in map_b and map_a[name] != map_b[name]:
            (_, ta, da) = map_a[name]
            (_, tb, db) = map_b[name]
            diffs.append("parameter %r: (type=%r, default=%r) != (type=%r, default=%r)" % (
                name, ta, da, tb, db))
    common_a = [n for n in names_a if n in map_b]
    common_b = [n for n in names_b if n in map_a]
    if common_a != common_b:
        diffs.append("parameter order differs: %r != %r" % (common_a, common_b))

    diffs.extend(_compare_sources(a["sources"], b["sources"], ""))
    return diffs


def main(path=REPORT_BIN):
    info = describe(path)
    print("title      :", info["title"])
    print("parameters :", info["parameters"])
    print("layout     : %d chars" % len(info["layout_xml"] or ""))
    print("data sources:")
    for depth, key, toks, sql in _flatten(info["sources"]):
        print("   %s%-22s tokens=%s %s" % (
            "    " * depth, key, list(toks), _sql_fingerprint(sql)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else REPORT_BIN))
