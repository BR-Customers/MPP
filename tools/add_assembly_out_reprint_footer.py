"""One-off edit of the two Assembly OUT views (2026-09-17 shipping-label reprint).

  Appends a `Footer` flex row as the last child of `root` in
    Views/ShopFloor/AssemblySerialized
    Views/ShopFloor/AssemblyNonSerialized
  holding one button, "Reprint Shipping Label", that opens
  Components/PlantFloor/ShippingLabelReprint for this cell + terminal.

SURGICAL, not a re-dump. Both files mix Designer-escaped (\\u003d) and hand-edited
strings, so a json.load/json.dump round-trip would rewrite dozens of unrelated
lines. Instead the Footer node is spliced in as text just before the closing `]`
of root.children, and the result is verified by re-parsing: it must equal the
original document with exactly that one node appended. Anything else aborts.

Idempotent: a view that already has a root-level `Footer` is left alone.
Close both views in Designer first, then run scan.ps1.

Usage: python tools/add_assembly_out_reprint_footer.py [--check]
"""

import io
import json
import sys

VIEWS = [
    "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblySerialized/view.json",
    "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized/view.json",
]

OPEN_POPUP = (
    "\tsystem.perspective.openPopup(\"mpp-shipping-reprint\", "
    "\"BlueRidge/Components/PlantFloor/ShippingLabelReprint\", "
    "params={\"cellLocationId\": self.session.custom.cell.locationId, "
    "\"terminalLocationId\": self.session.custom.terminal.terminalLocationId}, "
    "modal=True, showCloseIcon=True)")

FOOTER = {
    "type": "ia.container.flex",
    "meta": {"name": "Footer"},
    "position": {"shrink": 0},
    "props": {
        "direction": "row",
        "alignItems": "center",
        "justify": "flex-end",
        "style": {"classes": "modal-footer", "gap": "10px"},
    },
    "children": [
        {
            "type": "ia.input.button",
            "meta": {"name": "ReprintShippingLabelButton"},
            "position": {"basis": "220px", "shrink": 0},
            "events": {"component": {"onActionPerformed": {
                "type": "script", "scope": "G", "config": {"script": OPEN_POPUP}}}},
            "props": {"text": "Reprint Shipping Label",
                      "style": {"classes": "pf-btn pf-btn-secondary"}},
        }
    ],
}

BS = chr(92)
ESC = {"=": BS + "u003d", "<": BS + "u003c", ">": BS + "u003e",
       "'": BS + "u0027", "&": BS + "u0026"}


def gson_escape(s):
    """GSON's html-safe escapes inside JSON strings (what Designer writes)."""
    out, i, n, instr = [], 0, len(s), False
    while i < n:
        c = s[i]
        if instr:
            if c == BS:
                out.append(s[i:i + 2])
                i += 2
                continue
            if c == '"':
                instr = False
            elif c in ESC:
                c = ESC[c]
        elif c == '"':
            instr = True
        out.append(c)
        i += 1
    return "".join(out)


def root_children_close(text):
    """Index of the `]` closing root.children. Walks the text tracking strings and
    nesting so braces inside string values are ignored."""
    i, n = 0, len(text)
    stack = []            # (char, key-at-open)
    pending_key = None
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while text[j] != '"':
                j += 2 if text[j] == BS else 1
            s = text[i + 1:j]
            k = j + 1
            while text[k] in " \t\r\n":
                k += 1
            if text[k] == ":":
                pending_key = s
            i = j + 1
            continue
        if c in "{[":
            stack.append((c, pending_key))
            pending_key = None
        elif c in "}]":
            opener, key = stack.pop()
            path = [kk for (_, kk) in stack] + [key]
            if c == "]" and path == [None, "root", "children"]:
                return i
        elif c == ",":
            pending_key = None
        i += 1
    raise ValueError("root.children not found")


def apply(raw):
    doc = json.loads(raw)
    names = [c.get("meta", {}).get("name") for c in doc["root"]["children"]]
    if "Footer" in names:
        return None
    nl = "\r\n" if "\r\n" in raw else "\n"
    close = root_children_close(raw)
    # Back up over the whitespace before `]` so the new node follows the last child.
    k = close
    while raw[k - 1] in " \t\r\n":
        k -= 1
    body = json.dumps(FOOTER, indent=2, ensure_ascii=True)
    body = gson_escape(body)
    indent = "      "
    body = (nl + indent).join(body.split("\n"))
    out = raw[:k] + "," + nl + indent + body + raw[k:]
    # Verify: original + exactly one appended node, nothing else.
    expect = json.loads(raw)
    expect["root"]["children"].append(FOOTER)
    if json.loads(out) != expect:
        raise AssertionError("splice changed more than the Footer node")
    return out


def main():
    check = "--check" in sys.argv
    for path in VIEWS:
        raw = io.open(path, encoding="utf-8", newline="").read()
        out = apply(raw)
        if out is None:
            print("already has Footer: %s" % path)
            continue
        if check:
            print("would add Footer: %s" % path)
            continue
        io.open(path, "w", encoding="utf-8", newline="").write(out)
        print("added Footer: %s" % path)


if __name__ == "__main__":
    main()
