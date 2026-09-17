"""Shot-count / shot-limit input handling on the Config Tool Tools screen.

The two shot fields are ia.input.text-field, so Perspective writes STRINGS
back into view.custom.editDraft.meta. The die manager types thousands
separators ("1,000,000"). Before this change Tool.update() parsed with
int(float(v)), which fails on a comma and fell back to None -- silently
clearing the shot limit. These tests pin the pure helpers:

  * a comma'd value parses to an int; garbage is REJECTED, never None'd
  * the loaded meta seeds both fields as formatted strings, so a
    text-field writeback of the same text does not dirty the draft
  * a shot-count change without a note is refused before any write

Run: python -m pytest ignition/tests/test_tool_shot_inputs.py
"""

import ast
import io
import json
import os

import pytest

MODULE = os.path.join(
    os.path.dirname(__file__), os.pardir,
    "projects", "Core", "ignition", "script-python",
    "BlueRidge", "Parts", "Tool", "code.py",
)

WANTED = ("_parseShots", "_formatShots", "_metaForEditor", "_shotEdits")


def load_helpers(path=MODULE):
    """Exec only the self-contained helpers, so the test needs no Ignition."""
    src = io.open(path, encoding="utf-8").read()
    tree = ast.parse(src)
    keep = [n for n in tree.body
            if isinstance(n, ast.FunctionDef) and n.name in WANTED]
    ns = {}
    exec(compile(ast.Module(body=keep, type_ignores=[]), path, "exec"), ns)
    return ns


@pytest.fixture(scope="module")
def h():
    ns = load_helpers()
    missing = [n for n in WANTED if n not in ns]
    if missing:
        pytest.fail("helper(s) missing from the module: %s" % ", ".join(missing))
    return ns


TOOL_ROW = {
    "Id": 7, "Code": "DM0124", "Name": "6MA die", "Description": None,
    "ToolTypeCode": "Die", "ShotCount": 812400, "ShotLimit": 1000000,
    "DeprecatedAt": None,
}


@pytest.mark.parametrize("text,expected", [
    ("1,000,000", 1000000),
    (" 850 000 ", 850000),
    ("0", 0),
    (1200, 1200),
])
def test_parse_accepts_separators(h, text, expected):
    assert h["_parseShots"](text, "Shot Limit") == (expected, None)


@pytest.mark.parametrize("blank", [None, "", "   "])
def test_parse_blank_is_none_without_error(h, blank):
    assert h["_parseShots"](blank, "Shot Limit") == (None, None)


@pytest.mark.parametrize("bad", ["12a", "1.5", "-5", "1,00x"])
def test_parse_rejects_garbage(h, bad):
    value, error = h["_parseShots"](bad, "Shot Limit")
    assert value is None
    assert error == "Shot Limit must be a whole number of shots (got '%s')." % bad.strip()


def test_format(h):
    assert h["_formatShots"](850000) == "850,000"
    assert h["_formatShots"](0) == "0"
    assert h["_formatShots"](None) == ""
    assert h["_formatShots"]("") == ""


def test_meta_seeds_formatted_strings(h):
    meta = h["_metaForEditor"](dict(TOOL_ROW))
    assert meta["ShotCount"] == "812,400"
    assert meta["ShotLimit"] == "1,000,000"
    assert meta["ShotCountLoaded"] == 812400
    assert meta["ShotCountNote"] == ""
    assert meta["Description"] == ""
    assert meta["deprecated"] is False


def test_meta_blank_limit(h):
    row = dict(TOOL_ROW, ShotLimit=None)
    assert h["_metaForEditor"](row)["ShotLimit"] == ""


def test_text_field_writeback_does_not_dirty(h):
    """The dirty compare is jsonEncode(editDraft) != jsonEncode(selected);
    a text field writing back the same string must be a no-op."""
    baseline = h["_metaForEditor"](dict(TOOL_ROW))
    draft = dict(baseline)
    draft["ShotCount"] = str(draft["ShotCount"])
    draft["ShotLimit"] = str(draft["ShotLimit"])
    assert json.dumps(draft, sort_keys=True) == json.dumps(baseline, sort_keys=True)


def _data(**over):
    base = {"ShotLimit": "1,000,000", "ShotCount": "812,400",
            "ShotCountLoaded": 812400, "ShotCountNote": ""}
    base.update(over)
    return base


def test_edits_unchanged_count(h):
    e = h["_shotEdits"](_data())
    assert e == {"error": None, "shotLimit": 1000000, "shotCount": 812400,
                 "shotCountChanged": False, "note": None}


def test_edits_changed_count_needs_note(h):
    e = h["_shotEdits"](_data(ShotCount="850,000", ShotCountNote="  "))
    assert e["error"] == "Enter a note explaining the shot count change."


def test_edits_changed_count_with_note(h):
    e = h["_shotEdits"](_data(ShotCount="850,000", ShotCountNote=" from die card "))
    assert e == {"error": None, "shotLimit": 1000000, "shotCount": 850000,
                 "shotCountChanged": True, "note": "from die card"}


def test_edits_blank_count_is_an_error(h):
    e = h["_shotEdits"](_data(ShotCount=""))
    assert e["error"] == "Current Shots cannot be blank."


def test_edits_bad_limit_is_an_error_not_a_clear(h):
    e = h["_shotEdits"](_data(ShotLimit="1,0O0"))
    assert e["error"] == "Shot Limit must be a whole number of shots (got '1,0O0')."


def test_edits_blank_limit_clears(h):
    e = h["_shotEdits"](_data(ShotLimit=""))
    assert e["error"] is None
    assert e["shotLimit"] is None
