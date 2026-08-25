"""Prove the committed generator reproduces the pre-task Lot Detail report.

This is the actual evidence behind Task 1's claim ("the generator reproduces the
original report"), not an assertion of it. It:

  1. Extracts the ORIGINAL pre-task data.bin straight from git (commit f4f71b95,
     the last commit before the report was refactored into source), byte-exact.
  2. Runs the checked-in generator's build() in-memory to get the rebuilt bytes.
  3. Runs verify_lot_detail_report.compare() between the two.

The only difference the task intentionally introduced is the dead `Genealogy`
data source, dropped during the refactor. That is asserted explicitly; any other
difference fails the test with the specific diff line(s) printed.

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

from verify_lot_detail_report import compare  # noqa: E402
from build_lot_detail_report import build      # noqa: E402

ORIGINAL_COMMIT = "f4f71b95"
ORIGINAL_PATH = ("ignition/projects/MPP/com.inductiveautomation.reporting/"
                  "reports/Lot Detail/data.bin")
EXPECTED_ONLY_A_DIFF = "<root>: source key 'Genealogy' present only in A"


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

    unexpected = [d for d in diffs if not d.startswith(EXPECTED_ONLY_A_DIFF)]
    saw_expected_drop = any(d.startswith(EXPECTED_ONLY_A_DIFF) for d in diffs)

    if unexpected:
        print("FAIL -- unexpected structural differences between original and rebuild:")
        for d in unexpected:
            print("  -", d)
        return 1

    if saw_expected_drop:
        print("PASS -- rebuild matches original exactly, except the "
              "deliberately-dropped dead 'Genealogy' data source.")
    else:
        print("PASS -- rebuild matches original exactly (no 'Genealogy' source "
              "was present in the original to drop).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
