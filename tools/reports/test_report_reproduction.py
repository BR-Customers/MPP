"""Prove the committed generator reproduces the pre-task Lot Detail report.

This is the actual evidence behind Task 1's claim ("the generator reproduces the
original report"), not an assertion of it. It:

  1. Extracts the ORIGINAL pre-task data.bin straight from git (commit f4f71b95,
     the last commit before the report was refactored into source), byte-exact.
  2. Runs the checked-in generator's build() in-memory to get the rebuilt bytes.
  3. Runs verify_lot_detail_report.compare() between the two.

Two differences are intentionally introduced and asserted explicitly here; any
OTHER difference fails the test with the specific diff line(s) printed:

  1. The dead `Genealogy` data source, dropped during the source refactor
     (Task 1). OPTIONAL -- per Task 1's report this source never existed in
     the real original, so this diff has never once fired in practice.
  2. The `AncestorSteps` nested child added under `GenealogyAncestors`
     (Task 3) -- runs `Lots.Lot_GetLifecycle` once per ancestor row, bound to
     that row's `RelatedLotId` column. Data-only change; the report layout does
     not reference it yet, so this diff is expected on every rebuild from here
     on, not just once. MANDATORY -- if this diff stops appearing, the nesting
     was silently reverted and the test fails loudly rather than passing.

     compare() only diffs fields for keys present on both sides, so the A/B
     diff alone can prove `AncestorSteps` EXISTS but says nothing about its
     CONTENT -- a child rebound to the wrong token (e.g. `{LotId}` instead of
     `{RelatedLotId}`) still produces zero diffs. This test additionally
     asserts the new node's key, tokens and SQL directly via describe() on
     the freshly-built binary.

Run from the repo root:

    python tools/reports/test_report_reproduction.py
"""
import io
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from verify_lot_detail_report import compare, describe  # noqa: E402
from build_lot_detail_report import build      # noqa: E402

ORIGINAL_COMMIT = "f4f71b95"
ORIGINAL_PATH = ("ignition/projects/MPP/com.inductiveautomation.reporting/"
                  "reports/Lot Detail/data.bin")
EXPECTED_ONLY_A_DIFF = "<root>: source key 'Genealogy' present only in A"
EXPECTED_ONLY_B_DIFF = ("[key=GenealogyAncestors].children: source key "
                        "'AncestorSteps' present only in B")
# 3. The Summary SQL gained four section-count sub-selects (Task 5), so its SQL no
#    longer matches the original byte-for-byte. Matched by PREFIX, not by hash: the
#    hash changes on every wording tweak to the SQL comments, and a test that has to
#    be re-pinned after each edit gets re-pinned without thought. The count columns
#    themselves are asserted by name below.
EXPECTED_SUMMARY_DIFF_PREFIX = "[key=Summary] sql differs"
EXPECTED_SUMMARY_COLUMNS = ("ancestor_count", "descendant_count",
                            "container_count", "event_count")

# Content of the AncestorSteps nested child that Task 3 added. The A/B diff
# above only proves the KEY 'AncestorSteps' exists on the rebuild side -- it is
# silent about what that node actually contains (compare() only diffs fields
# for keys present on BOTH sides). These are asserted directly against
# describe() on the freshly-built binary, independent of the original.
EXPECTED_ANCESTOR_PARENT_KEY = "GenealogyAncestors"
EXPECTED_ANCESTOR_CHILD_KEY = "AncestorSteps"
EXPECTED_ANCESTOR_CHILD_TOKENS = ["{RelatedLotId}"]
EXPECTED_ANCESTOR_CHILD_SQL = "EXEC Lots.Lot_GetLifecycle ?"


def _git_show_binary(commit, path):
    """`git show <commit>:<path>`, returned as raw bytes (never text-mode)."""
    proc = subprocess.run(
        ["git", "show", "%s:%s" % (commit, path)],
        cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if proc.returncode != 0:
        raise RuntimeError("git show failed for %s:%s -- %s" % (
            commit, path, proc.stderr.decode("utf-8", "replace")))
    return proc.stdout


def main():
    original_bytes = _git_show_binary(ORIGINAL_COMMIT, ORIGINAL_PATH)
    rebuilt_bytes = build()

    tmp_dir = tempfile.mkdtemp(prefix="lot_detail_repro_")
    original_path = os.path.join(tmp_dir, "original_data.bin")
    rebuilt_path = os.path.join(tmp_dir, "rebuilt_data.bin")
    io.open(original_path, "wb").write(original_bytes)
    io.open(rebuilt_path, "wb").write(rebuilt_bytes)

    diffs = compare(original_path, rebuilt_path)

    expected_diffs = (EXPECTED_ONLY_A_DIFF, EXPECTED_ONLY_B_DIFF)
    unexpected = [d for d in diffs
                  if d not in expected_diffs
                  and not d.startswith(EXPECTED_SUMMARY_DIFF_PREFIX)]
    saw_expected_drop = EXPECTED_ONLY_A_DIFF in diffs
    saw_expected_nest = EXPECTED_ONLY_B_DIFF in diffs

    if unexpected:
        print("FAIL -- unexpected structural differences between original and rebuild:")
        for d in unexpected:
            print("  -", d)
        return 1

    # The 'Genealogy' drop is genuinely optional -- per Task 1's report, that
    # source never existed in the real original, so this diff has never once
    # fired and may never fire. The 'AncestorSteps' nesting is NOT optional:
    # it is the one thing Task 3 exists to establish. If it silently stops
    # showing up, the nesting was reverted (or never built), and that must
    # fail loudly rather than read as an unqualified pass.
    if not saw_expected_nest:
        print("FAIL -- expected diff not found: %r" % EXPECTED_ONLY_B_DIFF)
        print("        The 'AncestorSteps' nested child under "
              "'GenealogyAncestors' appears to have been dropped from the "
              "generator -- rebuild now matches the pre-Task-3 original "
              "exactly, which means the nesting this test exists to protect "
              "is gone.")
        return 1

    # Direct content assertions on the freshly-built binary. compare() only
    # diffs fields for keys present on BOTH sides, so it is blind to what the
    # new 'AncestorSteps' node actually contains (e.g. a token typo like
    # '{LotId}' instead of '{RelatedLotId}' produces zero diffs, since the
    # key doesn't exist in the original to compare against). Assert its
    # shape directly instead of relying on the A/B diff for it.
    rebuilt_info = describe(rebuilt_path)
    parent = next((s for s in rebuilt_info["sources"]
                   if s["key"] == EXPECTED_ANCESTOR_PARENT_KEY), None)
    if parent is None:
        print("FAIL -- data source %r not found in rebuild." %
              EXPECTED_ANCESTOR_PARENT_KEY)
        return 1
    if len(parent["children"]) != 1:
        print("FAIL -- %r has %d children, expected exactly 1: %r" % (
            EXPECTED_ANCESTOR_PARENT_KEY, len(parent["children"]), parent["children"]))
        return 1
    child = parent["children"][0]
    if child["key"] != EXPECTED_ANCESTOR_CHILD_KEY:
        print("FAIL -- %r child key %r != %r" % (
            EXPECTED_ANCESTOR_PARENT_KEY, child["key"], EXPECTED_ANCESTOR_CHILD_KEY))
        return 1
    if list(child["tokens"]) != EXPECTED_ANCESTOR_CHILD_TOKENS:
        print("FAIL -- %r tokens %r != %r" % (
            EXPECTED_ANCESTOR_CHILD_KEY, child["tokens"], EXPECTED_ANCESTOR_CHILD_TOKENS))
        return 1
    if child["sql"] != EXPECTED_ANCESTOR_CHILD_SQL:
        print("FAIL -- %r sql %r != %r" % (
            EXPECTED_ANCESTOR_CHILD_KEY, child["sql"], EXPECTED_ANCESTOR_CHILD_SQL))
        return 1

    summary = next((s for s in rebuilt_info["sources"] if s["key"] == "Summary"), None)
    if summary is None:
        print("FAIL -- 'Summary' data source not found in rebuild.")
        return 1
    missing = [c for c in EXPECTED_SUMMARY_COLUMNS if c not in summary["sql"]]
    if missing:
        print("FAIL -- Summary SQL is missing section-count columns: %r. The page "
              "subtitles bind to these; without them every count renders as "
              "<N/A> and an empty section is indistinguishable from a broken "
              "one again." % (missing,))
        return 1

    notes = []
    if saw_expected_drop:
        notes.append("the deliberately-dropped dead 'Genealogy' data source")
    if saw_expected_nest:
        notes.append("the deliberately-added 'AncestorSteps' nested child "
                     "under 'GenealogyAncestors'")
    notes.append("the section-count columns added to Summary")
    if notes:
        print("PASS -- rebuild matches original exactly, except %s." % " and ".join(notes))
    else:
        print("PASS -- rebuild matches original exactly (neither expected "
              "difference was present).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
