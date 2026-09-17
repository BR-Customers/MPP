"""One-off edit of the Config Tool Tools view (2026-09-17 shot-count correction).

  * FieldShotCount: "Total Shots" read-only label -> "Current Shots" text field
    bound bidirectionally to view.custom.editDraft.meta.ShotCount.
  * New FieldRowShotCountNote under FieldRowShotLimit, shown only while the
    typed count differs from the loaded one.
  * custom.selected / custom.editDraft defaults: drop the pickled live row,
    seed the full empty meta shape (incl. ShotCountLoaded / ShotCountNote).

Re-runnable: it rebuilds the targeted nodes from scratch each time.
Close the view in Designer first, then run scan.ps1.

Usage: python tools/edit_tools_view_shot_count.py [--check]
"""

import io
import json
import sys

VIEW = ("ignition/projects/MPP_Config/com.inductiveautomation.perspective/"
        "views/BlueRidge/Views/Parts/Tools/view.json")

BS = chr(92)
ESC = {"=": BS + "u003d", "<": BS + "u003c", ">": BS + "u003e",
       "'": BS + "u0027", "&": BS + "u0026"}


def dump(obj):
    """json.dumps(indent=2) with GSON's html-safe escapes inside strings."""
    s = json.dumps(obj, indent=2, ensure_ascii=False)
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


def find(node, name):
    if isinstance(node, dict):
        if node.get("meta", {}).get("name") == name:
            return node
        for v in node.values():
            hit = find(v, name)
            if hit is not None:
                return hit
    elif isinstance(node, list):
        for v in node:
            hit = find(v, name)
            if hit is not None:
                return hit
    return None


def find_parent(node, name):
    if isinstance(node, dict):
        for c in node.get("children", []) or []:
            if c.get("meta", {}).get("name") == name:
                return node
        for v in node.values():
            hit = find_parent(v, name)
            if hit is not None:
                return hit
    elif isinstance(node, list):
        for v in node:
            hit = find_parent(v, name)
            if hit is not None:
                return hit
    return None


EMPTY_META = {
    "Id": None, "ToolTypeId": None, "ToolTypeCode": "", "ToolTypeName": "",
    "HasCavities": False, "Code": "", "Name": "", "Description": "",
    "DieRankId": None, "DieRankCode": None, "DieRankName": None,
    "StatusCodeId": None, "StatusCode": "", "StatusName": "",
    "CreatedAt": None, "UpdatedAt": None, "CreatedByUserId": None,
    "UpdatedByUserId": None, "DeprecatedAt": None,
    "ShotCount": "", "ShotLimit": "", "ShotsRemaining": None,
    "PercentOfLimit": None, "IsNearLimit": False, "IsOverLimit": False,
    "ShotCountLoaded": 0, "ShotCountNote": "", "deprecated": False,
}

ENABLED_EXPR = "!{view.custom.selected.meta.deprecated}"
CHANGED_EXPR = ("{view.custom.editDraft.meta.ShotCount} != "
                "{view.custom.selected.meta.ShotCount}")


def text_input(name, path):
    return {
        "meta": {"name": name},
        "propConfig": {
            "props.enabled": {"binding": {"config": {"expression": ENABLED_EXPR},
                                          "type": "expr"}},
            "props.text": {"binding": {"config": {"bidirectional": True, "path": path},
                                       "type": "property"}},
        },
        "props": {"deferUpdates": False,
                  "style": {"classes": "search-input", "width": "100%"}},
        "type": "ia.input.text-field",
    }


def label(name, text):
    return {"meta": {"name": name},
            "props": {"style": {"classes": "field-label"}, "text": text},
            "type": "ia.display.label"}


def apply(view):
    root = view["root"]

    # 1. Current Shots field
    field = find(root, "FieldShotCount")
    assert field is not None, "FieldShotCount not found"
    field["children"] = [
        label("LabelShotCount", "Current Shots"),
        text_input("InputShotCount", "view.custom.editDraft.meta.ShotCount"),
    ]

    # 2. Shot Limit input commits on keystroke too (Save reads the draft)
    limit = find(root, "InputShotLimit")
    assert limit is not None, "InputShotLimit not found"
    limit.setdefault("props", {})["deferUpdates"] = False

    # 3. Note row directly under FieldRowShotLimit
    header = find_parent(root, "FieldRowShotLimit")
    assert header is not None, "FieldRowShotLimit parent not found"
    kids = [c for c in header["children"]
            if c.get("meta", {}).get("name") != "FieldRowShotCountNote"]
    at = [c.get("meta", {}).get("name") for c in kids].index("FieldRowShotLimit") + 1
    note_row = {
        "children": [{
            "children": [
                label("LabelShotCountNote", "Shot Count Change Note (required)"),
                text_input("InputShotCountNote", "view.custom.editDraft.meta.ShotCountNote"),
            ],
            "meta": {"name": "FieldShotCountNote"},
            "position": {"basis": "0", "grow": 1},
            "props": {"direction": "column",
                      "style": {"classes": "field", "gap": "2px"}},
            "type": "ia.container.flex",
        }],
        "meta": {"name": "FieldRowShotCountNote"},
        "propConfig": {
            # position.display, like FieldRowShotLimit: the row takes no
            # space until the typed count differs from the loaded one.
            "position.display": {"binding": {"config": {"expression": CHANGED_EXPR},
                                             "type": "expr"}},
        },
        "props": {"style": {"classes": "field-row", "gap": "12px"}},
        "type": "ia.container.flex",
    }
    kids.insert(at, note_row)
    header["children"] = kids

    # 4. Clean, fully-shaped custom defaults (no pickled live row)
    view.setdefault("custom", {})
    view["custom"]["selected"] = {"meta": dict(EMPTY_META)}
    view["custom"]["editDraft"] = {"meta": dict(EMPTY_META)}
    return view


def main():
    raw = io.open(VIEW, encoding="utf-8", newline="").read()
    out = dump(apply(json.loads(raw)))
    if raw.endswith("\n") and not out.endswith("\n"):
        out += "\n"
    if "--check" in sys.argv:
        print("would change" if out != raw else "no change")
        return
    io.open(VIEW, "w", encoding="utf-8", newline="").write(out)
    print("wrote %s" % VIEW)


if __name__ == "__main__":
    main()
