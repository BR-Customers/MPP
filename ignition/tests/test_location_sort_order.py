"""Regression guard for the PlantHierarchy "Unsaved changes" latch.

BlueRidge/Location/Location's editor-meta must carry SortOrder in the type
the Sort Order editor actually holds it in. That editor is an
ia.input.text-field whose props.text (a String prop) is bound
bidirectionally to view.custom.state.editDraft.sortOrder, so Perspective
coerces whatever we seed and writes the STRING form back into the draft.

PlantHierarchy's dirty indicator is

    jsonEncode(state.editDraft) != jsonEncode(state.selected)

so seeding the raw INT from the DB left the baseline at 3 while the draft
held "3" -- unequal forever. "Unsaved changes" latched on with nothing
edited and survived every Save.

These tests exec the pure helpers straight out of the Jython module (no
gateway, no Ignition runtime) and assert that a text-field writeback is a
no-op against the baseline.

Run: python -m pytest ignition/tests/test_location_sort_order.py
"""

import ast
import io
import json
import os

import pytest

MODULE = os.path.join(
    os.path.dirname(__file__), os.pardir,
    "projects", "Core", "ignition", "script-python",
    "BlueRidge", "Location", "Location", "code.py",
)

WANTED = ("_sortOrderForEditor", "_sortOrderForProc", "metaFromLocation")


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
def helpers():
    # Deliberately NOT asserting the new helpers exist. The writeback test
    # below needs only metaFromLocation, so it runs against the pre-fix
    # module too and fails there with the real JSON mismatch -- which is
    # what makes it a regression test rather than a presence check.
    return load_helpers()


def _need(ns, *names):
    missing = [n for n in names if n not in ns]
    if missing:
        pytest.fail("helper(s) missing from the module: %s" % ", ".join(missing))


def test_baseline_holds_sort_order_as_a_string(helpers):
    """metaFromLocation is the baseline half of the dirty compare."""
    _need(helpers, "metaFromLocation")
    meta = helpers["metaFromLocation"]({
        "id": 41, "parentLocationId": 7, "locationTypeDefinitionId": 16,
        "code": "MA2-6MACH-AOUT2", "name": "METTs Assembly Out B",
        "description": "MA2-6MACH-AOUT2", "sortOrder": 3,
    })
    assert meta["sortOrder"] == "3"


def test_text_field_writeback_does_not_dirty_the_draft(helpers):
    """THE bug: the text field coerces int -> str and writes it back. After
       that writeback the draft must still JSON-match the baseline."""
    _need(helpers, "metaFromLocation")
    row = {
        "id": 41, "parentLocationId": 7, "locationTypeDefinitionId": 16,
        "code": "MA2-6MACH-AOUT2", "name": "METTs Assembly Out B",
        "description": "MA2-6MACH-AOUT2", "sortOrder": 3,
    }
    baseline = helpers["metaFromLocation"](row)
    # What Perspective leaves in editDraft once props.text has rendered.
    draft = dict(baseline, sortOrder="%s" % baseline["sortOrder"])
    assert json.dumps(draft, sort_keys=True) == json.dumps(baseline, sort_keys=True)


def test_blank_sort_order_is_a_string_not_none(helpers):
    """emptyMeta's create-mode blank has to survive the same writeback."""
    _need(helpers, "_sortOrderForEditor")
    assert helpers["_sortOrderForEditor"](None) == ""
    assert helpers["_sortOrderForEditor"]("") == ""


def test_editor_form_is_idempotent(helpers):
    _need(helpers, "_sortOrderForEditor")
    fn = helpers["_sortOrderForEditor"]
    assert fn(3) == fn("3") == fn(fn(3)) == "3"


@pytest.mark.parametrize("value,expected", [
    (None, None),   # create: proc auto-assigns MAX+1 among active siblings
    ("", None),     # update: proc preserves the current SortOrder
    ("3", 3),       # the sqlType:2 parameter wants a real int
    (3, 3),
    ("3x", None),   # non-numeric -> caller toasts and rejects
    ("abc", None),
])
def test_proc_form(helpers, value, expected):
    _need(helpers, "_sortOrderForProc")
    assert helpers["_sortOrderForProc"](value) == expected
