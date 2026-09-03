"""Assert NestingReportBuilder emits a real setChildren SubQuery.

Run: python tools/reports/test_nesting_builder.py
"""
import os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from nesting_builder import NestingReportBuilder          # noqa: E402
from verify_lot_detail_report import describe             # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
DONOR = os.path.join(REPO, "ignition", "projects", "MPP",
                     "com.inductiveautomation.reporting", "reports",
                     "sample for claude", "data.bin")


def test_nested_child_is_emitted():
    rb = NestingReportBuilder(DONOR)
    rb.set_title("NestTest")
    rb.set_parameters([("LotId", "Long", "0")])
    rb.add_nested_query(
        "Parent", "EXEC Lots.Lot_GetGenealogyEdgeTree ?, N'Ancestors'", ["{LotId}"],
        children=[{"key": "Child", "sql": "EXEC Lots.Lot_GetLifecycle ?",
                   "tokens": ["{RelatedLotId}"], "children": []}])
    rb.set_layout("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<document version=\"14\"/>")
    rb.clear_snapshot()
    path = os.path.join(tempfile.mkdtemp(), "data.bin")
    open(path, "wb").write(rb.build())

    info = describe(path)
    parents = [s for s in info["sources"] if s["key"] == "Parent"]
    assert len(parents) == 1, "expected one Parent source, got %r" % (info["sources"],)
    parent = parents[0]
    assert parent["tokens"] == ["{LotId}"], parent["tokens"]
    assert len(parent["children"]) == 1, "no nested child emitted: %r" % (parent,)
    child = parent["children"][0]
    assert child["key"] == "Child", child["key"]
    assert child["tokens"] == ["{RelatedLotId}"], child["tokens"]
    assert "Lot_GetLifecycle" in child["sql"], child["sql"]
    print("PASS test_nested_child_is_emitted")


def test_grandchild_nesting_is_emitted():
    """Parent -> Child -> Grandchild must round-trip as a real three-level
    chain, not get flattened to two levels (parent+child) or one (parent only).
    """
    rb = NestingReportBuilder(DONOR)
    rb.set_title("NestTest3")
    rb.set_parameters([("LotId", "Long", "0")])
    rb.add_nested_query(
        "Parent", "EXEC Lots.Lot_GetGenealogyEdgeTree ?, N'Ancestors'", ["{LotId}"],
        children=[{
            "key": "Child", "sql": "EXEC Lots.Lot_GetLifecycle ?",
            "tokens": ["{RelatedLotId}"],
            "children": [{
                "key": "Grandchild", "sql": "EXEC Lots.Lot_GetGenealogyEdgeTree ?, N'Ancestors'",
                "tokens": ["{ChildLotId}"], "children": [],
            }],
        }])
    rb.set_layout("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<document version=\"14\"/>")
    rb.clear_snapshot()
    path = os.path.join(tempfile.mkdtemp(), "data.bin")
    open(path, "wb").write(rb.build())

    info = describe(path)
    parents = [s for s in info["sources"] if s["key"] == "Parent"]
    assert len(parents) == 1, "expected one Parent source, got %r" % (info["sources"],)
    parent = parents[0]
    assert parent["tokens"] == ["{LotId}"], parent["tokens"]

    # Grandchild must NOT be flattened to top level.
    assert all(s["key"] != "Grandchild" for s in info["sources"]), (
        "grandchild flattened to top-level sources: %r" % (info["sources"],))

    assert len(parent["children"]) == 1, "no nested child emitted: %r" % (parent,)
    child = parent["children"][0]
    assert child["key"] == "Child", child["key"]
    assert child["tokens"] == ["{RelatedLotId}"], child["tokens"]
    assert "Lot_GetLifecycle" in child["sql"], child["sql"]

    # Grandchild must NOT be flattened onto the parent's children list either.
    assert all(s["key"] != "Grandchild" for s in parent["children"]), (
        "grandchild flattened onto parent's children: %r" % (parent["children"],))

    assert len(child["children"]) == 1, "no nested grandchild emitted: %r" % (child,)
    grandchild = child["children"][0]
    assert grandchild["key"] == "Grandchild", grandchild["key"]
    assert grandchild["tokens"] == ["{ChildLotId}"], grandchild["tokens"]
    assert "Lot_GetGenealogyEdgeTree" in grandchild["sql"], grandchild["sql"]
    assert grandchild["children"] == [], grandchild["children"]
    print("PASS test_grandchild_nesting_is_emitted")


if __name__ == "__main__":
    test_nested_child_is_emitted()
    test_grandchild_nesting_is_emitted()
