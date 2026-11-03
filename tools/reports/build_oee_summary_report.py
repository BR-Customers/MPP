#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Build the "OEE Summary" report (OEE dashboard spec
docs/superpowers/specs/2026-10-27-oee-dashboard-design.md sec 5.6).

The area screens' tables for all three areas in print form, for one period:
page 1 lists every area, ProductionArea group, unit and station with its
availability, unplanned / planned downtime minutes, good, scrap and quality;
page 2 holds each area's downtime by reason. Every figure comes from the
dashboard's own read procs (Oee.Dashboard_GetPeriod, _GetUnitSummary,
_GetDowntimeByReason) -- the report adds no arithmetic.

Parameters: ShiftId (Long, the anchor shift) and Zoom (Shift | Day | Week).
Registry key `oee_summary` in BlueRidge.Reports.

Regenerate and deploy:
    python tools/reports/build_oee_summary_report.py
    .\\scan.ps1
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from build_aggregate_reports import (L, write, title_block, HEAD_BG, BODY, MUTED, NUM_FMT)  # noqa: E402

TITLE = "OEE Summary"

# A ratio column (0.9767) printed as a percentage. DecimalFormat's % multiplies by 100.
RATIO_FMT = '<format type="number" pattern="#0.0%" null-string="--" />'

PARAMS = [("ShiftId", "Long", "0"),
          ("Zoom", "String", '"Shift"')]

PERIOD_SQL = "EXEC Oee.Dashboard_GetPeriod @Zoom = ?, @AnchorShiftId = ?, @Step = 0"
UNITS_SQL = "EXEC Oee.Dashboard_GetUnitSummary @Zoom = ?, @AnchorShiftId = ?, @AreaFamily = NULL"
REASON_SQL = ("EXEC Oee.Dashboard_GetDowntimeByReason @Zoom = ?, @AnchorShiftId = ?, "
              "@AreaFamily = N'%s', @LocationId = NULL")
TOKENS = ["{Zoom}", "{ShiftId}"]

UNIT_COLS = [
    ("Level",       50, "@RowKind@",                  None,      "left"),
    ("Name",       166, "@LocationName@",             None,      "left"),
    ("Avail.",      54, "@Availability@",             RATIO_FMT, "right"),
    ("Unplanned",   60, "@UnplannedDowntimeMinutes@", NUM_FMT,   "right"),
    ("Planned",     54, "@PlannedDowntimeMinutes@",   NUM_FMT,   "right"),
    ("Good",        56, "@Good@",                     NUM_FMT,   "right"),
    ("Scrap",       46, "@Scrap@",                    NUM_FMT,   "right"),
    ("Quality",     54, "@Quality@",                  RATIO_FMT, "right"),
]

FAMILIES = [("diecast", "Die Cast", "ReasonsDieCast"),
            ("trim", "Trim", "ReasonsTrim"),
            ("ma", "Machining & Assembly", "ReasonsMA")]


def reason_cols():
    return [("Reason", 128, "@ReasonDescription@", None, "left"),
            ("Min", 40, "@Minutes@", NUM_FMT, "right")]


def build():
    subtitle = "@Period.PeriodLabel@" + L.esc("  |  availability, downtime and quality by area and unit")
    note = ("Pooled, never averaged: availability = (base - unplanned) / base and quality = good / "
            "(good + scrap) over the units that ran. Minutes are entered durations. Non-reject scrap "
            "is excluded; trim quality is the shop's. A unit that did not run shows --.")
    page1 = "".join([
        L.page_open(),
        title_block(TITLE, subtitle),
        L.text(36, 120, 540, 24, L.esc(note), size=8, italic=True, color=MUTED),
        L.table(36, 148, 540, "Units", UNIT_COLS, HEAD_BG, BODY),
        L.page_close(),
    ])
    reason_blocks = []
    for i, (fam, name, key) in enumerate(FAMILIES):
        x = 36 + i * 186
        reason_blocks.append(L.text(x, 126, 168, 16, L.esc(name), size=11, bold=True, color=BODY))
        reason_blocks.append(L.table(x, 146, 168, key, reason_cols(), HEAD_BG, BODY))
    page2 = "".join([
        L.page_open(),
        title_block(TITLE + " - downtime by reason", subtitle),
        "".join(reason_blocks),
        L.page_close(),
    ])
    layout = "".join([L.doc_open(), page1, page2, L.doc_close()])
    queries = [("Period", PERIOD_SQL, TOKENS), ("Units", UNITS_SQL, TOKENS)]
    queries += [(key, REASON_SQL % fam, TOKENS) for fam, _, key in FAMILIES]
    write(TITLE, TITLE, PARAMS, queries, layout)


if __name__ == "__main__":
    build()
