"""Regenerate the Lot Detail report's data.bin from checked-in source.

The binary is an OUTPUT, never edited by hand. Run from the repo root:

    python tools/reports/build_lot_detail_report.py
    .\\scan.ps1

Clones the validated donor envelope (version-correct class/method signatures for
this gateway) and swaps in our title, parameters, data sources and layout.
"""
import io, os, sys, xml.dom.minidom

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.expanduser("~"), ".claude", "skills",
                                "ignition-reporting", "tools"))

from report_builder import ReportBuilder, RESOURCE_JSON   # noqa: E402
from lot_detail import queries                            # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
REPORTS = os.path.join(REPO, "ignition", "projects", "MPP",
                       "com.inductiveautomation.reporting", "reports")
DONOR = os.path.join(REPORTS, "sample for claude", "data.bin")
OUT_DIR = os.path.join(REPORTS, "Lot Detail")
LAYOUT = os.path.join(HERE, "lot_detail", "layout.xml")
TITLE = "Lot Detail"          # MUST equal the folder name and the registry reportPath


def build():
    layout_xml = io.open(LAYOUT, encoding="utf-8").read()
    # A raw & / < / > in a literal throws RMException at RENDER time, which the
    # gateway surfaces only as a generic "invalid report". Fail here instead.
    xml.dom.minidom.parseString(layout_xml.encode("utf-8"))

    rb = ReportBuilder(DONOR)
    rb.set_title(TITLE)
    rb.set_parameters(queries.PARAMETERS)
    for src in queries.DATA_SOURCES:
        rb.add_query(src["key"], src["sql"], src["tokens"])
    rb.set_layout(layout_xml)
    rb.clear_snapshot()
    return rb.build()


def main():
    data = build()
    if not os.path.isdir(OUT_DIR):
        os.makedirs(OUT_DIR)
    open(os.path.join(OUT_DIR, "data.bin"), "wb").write(data)
    io.open(os.path.join(OUT_DIR, "resource.json"), "w",
            encoding="utf-8", newline="\n").write(RESOURCE_JSON)
    print("wrote %s (%d bytes)" % (os.path.join(OUT_DIR, "data.bin"), len(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
