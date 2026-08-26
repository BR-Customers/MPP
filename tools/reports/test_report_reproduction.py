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
  2. The `AncestorSteps` ROOT data source (Tasks 3-4) -- runs
     `Lots.Lot_GetAncestorSteps`, returning one row per (ancestor, lifecycle
     step) for the subject LOT. MANDATORY -- if this diff stops appearing, the
     ancestor-history feature was silently reverted and the test fails loudly
     rather than passing.

     This was originally a NESTED child under `GenealogyAncestors` bound to
     `{RelatedLotId}`. The data worked, but nothing could DRAW it: verified by
     render 2026-08-26, a <table> nested inside a <table> renders nothing on
     this gateway, and a column-keyed <grouping> emits one band carrying the
     first row's value. The hierarchy was therefore flattened into SQL and the
     source promoted to a root query.

     compare() only diffs fields for keys present on both sides, so the A/B
     diff alone can prove `AncestorSteps` EXISTS but says nothing about its
     CONTENT -- a source rebound to the wrong proc still produces zero diffs.
     This test additionally asserts the node's key, tokens and SQL directly via
     describe() on the freshly-built binary. The specific silent-wrong-data
     failure it guards is a rebind to `Lots.Lot_GetLifecycle`, which would show
     the SUBJECT's own history under an "Ancestor Process History" heading.

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
EXPECTED_ONLY_B_DIFF = "<root>: source key 'AncestorSteps' present only in B"

# Content of the AncestorSteps root source. The A/B diff above only proves the
# KEY exists on the rebuild side -- it is silent about what that node actually
# contains (compare() only diffs fields for keys present on BOTH sides). These
# are asserted directly against describe() on the freshly-built binary.
EXPECTED_ANCESTOR_KEY = "AncestorSteps"
EXPECTED_ANCESTOR_TOKENS = ["{LotId}"]
EXPECTED_ANCESTOR_SQL = "EXEC Lots.Lot_GetAncestorSteps ?"
# The rebind that would silently show the WRONG lot's history under the
# "Ancestor Process History" heading. Named so the failure message can say so.
FORBIDDEN_ANCESTOR_SQL = "EXEC Lots.Lot_GetLifecycle ?"


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
    unexpected = [d for d in diffs if d not in expected_diffs]
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
        print("        The 'AncestorSteps' data source appears to have been "
              "dropped from the generator -- rebuild now matches the "
              "pre-Task-3 original exactly, which means the ancestor-history "
              "feature this test exists to protect is gone.")
        return 1

    # Direct content assertions on the freshly-built binary. compare() only
    # diffs fields for keys present on BOTH sides, so it is blind to what the
    # new 'AncestorSteps' node actually contains (e.g. a token typo like
    # '{LotId}' instead of '{RelatedLotId}' produces zero diffs, since the
    # key doesn't exist in the original to compare against). Assert its
    # shape directly instead of relying on the A/B diff for it.
    rebuilt_info = describe(rebuilt_path)
    node = next((s for s in rebuilt_info["sources"]
                 if s["key"] == EXPECTED_ANCESTOR_KEY), None)
    if node is None:
        print("FAIL -- data source %r not found in rebuild." % EXPECTED_ANCESTOR_KEY)
        return 1
    if node["sql"] == FORBIDDEN_ANCESTOR_SQL:
        print("FAIL -- %r is bound to %r, the SUBJECT lot's own lifecycle. The "
              "report would show the subject's history under an 'Ancestor "
              "Process History' heading -- populated, plausible and wrong." % (
                  EXPECTED_ANCESTOR_KEY, FORBIDDEN_ANCESTOR_SQL))
        return 1
    if node["sql"] != EXPECTED_ANCESTOR_SQL:
        print("FAIL -- %r sql %r != %r" % (
            EXPECTED_ANCESTOR_KEY, node["sql"], EXPECTED_ANCESTOR_SQL))
        return 1
    if list(node["tokens"]) != EXPECTED_ANCESTOR_TOKENS:
        print("FAIL -- %r tokens %r != %r" % (
            EXPECTED_ANCESTOR_KEY, node["tokens"], EXPECTED_ANCESTOR_TOKENS))
        return 1

    notes = []
    if saw_expected_drop:
        notes.append("the deliberately-dropped dead 'Genealogy' data source")
    if saw_expected_nest:
        notes.append("the deliberately-added 'AncestorSteps' data source")
    if notes:
        print("PASS -- rebuild matches original exactly, except %s." % " and ".join(notes))
    else:
        print("PASS -- rebuild matches original exactly (neither expected "
              "difference was present).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
