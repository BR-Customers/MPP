#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Build the five FDS-12-006 / 010 / 011 aggregate reports.

Spec: docs/superpowers/specs/2026-08-25-aggregate-reports-design.md

Discipline (per the ignition-reporting skill):
  * clone the validated MPP donor -- never fabricate the envelope;
  * folder name == set_title == the registry's reportPath, or the viewer says
    "Enter a valid report in the source property";
  * L.esc EVERY literal, pass only @tokens@ raw, and validate the layout XML
    parses before writing -- a raw & fails at RENDER time, not load.
"""
import io
import os
import sys
import xml.dom.minidom

TOOLS = r"C:/Users/JacquesPotgieter/.claude/skills/ignition-reporting/tools"
sys.path.insert(0, TOOLS)

import reportmill_layout as L
from report_builder import ReportBuilder

REPO = r"C:/Users/JacquesPotgieter/Documents/Dev/MPP"
DONOR = os.path.join(REPO, "ignition/projects/MPP/com.inductiveautomation.reporting/"
                           "reports/sample for claude/data.bin")
OUT = os.path.join(REPO, "ignition/projects/MPP/com.inductiveautomation.reporting/reports")

# MPP report palette, lifted from the existing Downtime Report so the five new
# ones sit in the same suite rather than looking bolted on.
INK      = "#0B1220"   # title band
ACCENT   = "#1888A8"   # cyan rule
HEAD_BG  = "#1F2C44"
HEAD_TXT = "#F0F3F8"
BODY     = "#1b2430"
MUTED    = "#6b788f"

RESOURCE_JSON = ('{\n  "scope": "A",\n  "version": 1,\n  "restricted": false,\n'
                 '  "overridable": true,\n  "files": [\n    "data.bin"\n  ],\n'
                 '  "attributes": {}\n}\n')

# ReportMill's format element uses pattern=, NOT format=. An unrecognised
# attribute invalidates the element and the whole report then fails to render
# with the generic "Enter a valid report in the source property" -- no error in
# the log pointing at the format. Shape copied verbatim from the working
# Downtime by Date Range report, null-string included.
DATE_FMT = '<format type="date" pattern="MMM d, yyyy" null-string="&lt;N/A&gt;" />'
DTM_FMT  = '<format type="date" pattern="MMM d  HH:mm" null-string="&lt;N/A&gt;" />'
NUM_FMT  = '<format type="number" pattern="#,##0" null-string="&lt;N/A&gt;" />'
PCT_FMT  = '<format type="number" pattern="#,##0.00" null-string="&lt;N/A&gt;" />'


def title_block(title, subtitle_tokens):
    """Standard MPP report masthead: ink band, cyan rule, title + subtitle."""
    return "".join([
        L.rect(36, 40, 540, 70, INK),
        L.rect(36, 110, 540, 3, ACCENT),
        L.text(51, 47, 510, 20, L.esc(title), size=17, bold=True, color=HEAD_TXT),
        L.text(51, 72, 510, 14, subtitle_tokens, size=10, color="#9AA8BF"),
        L.text(430, 756, 146, 18, "@Page@ of @PageMax@", size=9, color=MUTED, align="right"),
    ])


def nested_table(x, y, w, parent_key, parent_cols, child_blocks,
                 parent_row_h=15, header_h=18):
    """A parent list table with CHILD tables nested inside it.

    THREE RULES, each of which fails SILENTLY if broken -- a malformed nest
    renders NOTHING at all: no exception, no log line, no partial output. That
    is indistinguishable from the engine not supporting nesting, and it cost a
    lot of time before the shape was pinned down. Verified against the
    production Cryovac donor by render on 2026-08-26:

      1. The whole nest MUST be wrapped in <table-group>. A <table> placed
         directly inside another <table> renders nothing.
      2. Every child table carries the SAME width AND height as its parent and
         NO x/y of its own. The <table-group> positions the stack; ReportMill
         flows the children under each parent row. Giving a child its own
         narrower box or a y offset renders nothing.
      3. <tablerow title> must read exactly "<key> Header|Details"; a nested
         table binds by its BARE child key.

    An earlier version of this function claimed the Cryovac shape but emitted
    per-child y offsets and narrower child boxes -- breaking rules 1 and 2 --
    which is why `Rejects Part Matrix` shipped with its two detail sections
    invisible. Do not reintroduce child positioning: siblings stack on their
    own.

    child_blocks: list of (child_list_key, columns).
    """
    total = sum(c[0] for c in parent_cols)   # parent_cols is (width, token, align, bold)
    h = L.PAGE_H - y - 70
    p = ['<table-group x="%d" y="%d" width="%d" height="%d" useStroke="false">' % (x, y, w, h),
         '<table width="%d" height="%d" list-key="%s" startrowbreak="true">' % (w, h, parent_key),
         '<grouping key="%s" details="true" />' % parent_key]

    # Parent detail row: the per-part heading.
    p.append('<tablerow width="%d" height="%d" title="%s Details">' % (total, parent_row_h, parent_key))
    cx = 0
    for (cw, token, align, bold) in parent_cols:
        p.append('<row-cell-text x="%d" width="%d" height="%d">'
                 '<font logical_name="Times New Roman" style="%d" size="10.5" />'
                 '<color value="%s" /><pgraph align="%s" /><string>%s</string></row-cell-text>'
                 % (cx, cw, parent_row_h, 1 if bold else 0, BODY, align, token))
        cx += cw
    p.append('</tablerow>')

    # Child tables, nested INSIDE the parent element -- same width/height as the
    # parent, no x/y (rule 2). Siblings stack automatically.
    for (child_key, cols) in child_blocks:
        ctotal = sum(c[1] for c in cols)
        p.append('<table width="%d" height="%d" list-key="%s" startrowbreak="false">'
                 % (w, h, child_key))
        p.append('<grouping key="%s" header="true" details="true" />' % child_key)
        p.append('<tablerow width="%d" height="%d" title="%s Header">' % (ctotal, header_h, child_key))
        cx = 0
        for (lbl, cw, token, fmt, align) in cols:
            p.append('<row-cell-text x="%d" width="%d" height="%d">'
                     '<font logical_name="Times New Roman" style="1" size="8.5" />'
                     '<color value="%s" /><pgraph align="%s" /><string>%s</string></row-cell-text>'
                     % (cx, cw, header_h, MUTED, align, L.esc(lbl)))
            cx += cw
        p.append('</tablerow>')
        p.append('<tablerow y="%d" width="%d" height="14" title="%s Details">' % (header_h, ctotal, child_key))
        cx = 0
        for (lbl, cw, token, fmt, align) in cols:
            cell = ['<row-cell-text x="%d" width="%d" height="14">' % (cx, cw),
                    '<font logical_name="Times New Roman" style="0" size="9" />',
                    '<color value="%s" /><pgraph align="%s" /><string>%s</string>' % (BODY, align, token)]
            if fmt:
                cell.append(fmt)
            cell.append('</row-cell-text>')
            p.append("".join(cell))
            cx += cw
        p.append('</tablerow>')
        p.append('</table>')

    p.append('</table>')
    p.append('</table-group>')
    return "".join(p)


def write(folder, title, params, queries, layout_xml, nested=None):
    """Build one report. `queries` are flat; `nested` is one optional
    (data_key, sql, tokens, children) tuple."""
    # Validate the layout parses BEFORE writing -- a raw & would otherwise fail
    # at render time as a generic "invalid report".
    xml.dom.minidom.parseString(layout_xml.encode("utf-8"))

    rb = ReportBuilder(DONOR)
    rb.set_title(title)                      # MUST equal the folder name
    rb.set_parameters(params)
    for (key, sql, tokens) in queries:
        rb.add_query(key, sql, tokens)
    if nested:
        rb.add_nested_query(*nested)
    rb.set_layout(layout_xml)
    rb.clear_snapshot()

    d = os.path.join(OUT, folder)
    if not os.path.isdir(d):
        os.makedirs(d)
    open(os.path.join(d, "data.bin"), "wb").write(rb.build())
    io.open(os.path.join(d, "resource.json"), "w", encoding="utf-8",
            newline="\n").write(RESOURCE_JSON)
    print("  built %-32s title=%r  layout=%d chars" % (folder, title, len(layout_xml)))


# Spacing matches the working Downtime by Date Range report verbatim. A default
# expression that fails to evaluate leaves the parameter unset, which surfaces
# downstream as "Error executing query parameter expression {StartDate}".
DATE_PARAMS = [("StartDate", "Date", 'dateArithmetic(now(), -14, "day")'),
               ("EndDate",   "Date", "now()")]

# ---------------------------------------------------------------------------
# 1. Rejects - Transaction Detail
# ---------------------------------------------------------------------------
def build_rejects_detail():
    sql = ("EXEC Quality.Reject_SearchDetail @FromEt = ?, @ToEt = ?, "
           "@PartNumberLike = NULL, @DefectCodeId = NULL, @ChargeToPartyId = NULL, "
           "@LimitRows = 2000")
    cols = [
        ("Part",       104, "@ItemPartNumber@",    None,     "left"),
        ("LOT",         92, "@LotName@",           None,     "left"),
        ("Recorded",    84, "@RecordedAt@",        DTM_FMT,  "left"),
        ("Operator",    72, "@OperatorName@",      None,     "left"),
        ("Defect",     124, "@DefectDescription@", None,     "left"),
        ("Charge to",   72, "@ChargeToPartyName@", None,     "left"),
        ("Qty",         40, "@Quantity@",          NUM_FMT,  "right"),
    ]
    layout = "".join([
        L.doc_open(), L.page_open(),
        title_block("Rejects - Transaction Detail",
                    "@StartDate@ - @EndDate@" + L.esc("  |  every reject record in the window")),
        L.table(36, 126, 540, "Rejects", cols, HEAD_TXT, BODY),
        L.page_close(), L.doc_close(),
    ])
    write("Rejects Transaction Detail", "Rejects Transaction Detail", DATE_PARAMS,
          [("Rejects", sql, ["{StartDate}", "{EndDate}"])], layout)


# ---------------------------------------------------------------------------
# 2. Rejects - Plant Summary
# ---------------------------------------------------------------------------
def build_rejects_summary():
    dept_sql = "EXEC Quality.Reject_GetPlantSummary @FromEt = ?, @ToEt = ?"
    nrs_sql = "EXEC Quality.Reject_GetNonRejectScrap @FromEt = ?, @ToEt = ?"

    dept_cols = [
        ("Department",  180, "@ChargeToPartyName@", None,    "left"),
        ("Good pcs",    100, "@GoodPieces@",        NUM_FMT, "right"),
        ("Reject",       80, "@RejectPieces@",      NUM_FMT, "right"),
        ("Total",       100, "@TotalPieces@",       NUM_FMT, "right"),
        ("Reject %",     80, "@RejectPercent@",     PCT_FMT, "right"),
    ]
    nrs_cols = [
        ("Code",         60, "@DefectCode@",        None,    "left"),
        ("Description", 300, "@DefectDescription@", None,    "left"),
        ("Quantity",    180, "@Quantity@",          NUM_FMT, "right"),
    ]
    # The customer-scrap block has NO data source: there is no customer
    # dimension in the schema. Per Jacques 2026-08-25 the gap is stated ON the
    # report rather than silently omitted, so the printed page is itself the
    # prompt to MPP for the mapping.
    note = ("Customer scrap percentage - not available. This section requires a "
            "per-part customer assignment, which the MES does not yet hold. "
            "Supply the part-to-customer mapping to enable it.")
    layout = "".join([
        L.doc_open(), L.page_open(),
        title_block("Rejects - Plant Summary",
                    "@StartDate@ - @EndDate@" + L.esc("  |  departmental scrap")),
        L.text(36, 126, 540, 14, L.esc("Departmental scrap"), size=11, bold=True, color=BODY),
        L.table(36, 144, 540, "Departments", dept_cols, HEAD_TXT, BODY),
        L.text(36, 330, 540, 14, L.esc("Non-reject scrap"), size=11, bold=True, color=BODY),
        L.text(36, 346, 540, 12,
               L.esc("Counted, but excluded from every reject percentage above."),
               size=8.5, italic=True, color=MUTED),
        L.table(36, 364, 540, "NonRejectScrap", nrs_cols, HEAD_TXT, BODY),
        L.rect(36, 540, 540, 3, ACCENT),
        L.text(36, 552, 540, 14, L.esc("Customer scrap percentage"), size=11, bold=True, color=BODY),
        L.text(36, 570, 540, 44, L.esc(note), size=9, italic=True, color=MUTED),
        L.page_close(), L.doc_close(),
    ])
    write("Rejects Plant Summary", "Rejects Plant Summary", DATE_PARAMS,
          [("Departments", dept_sql, ["{StartDate}", "{EndDate}"]),
           ("NonRejectScrap", nrs_sql, ["{StartDate}", "{EndDate}"])], layout)


# ---------------------------------------------------------------------------
# 3. Rejects - Part Matrix  (NESTED: root parts -> party + defect children)
# ---------------------------------------------------------------------------
def build_rejects_matrix():
    root_sql = "EXEC Quality.Reject_GetPartMatrix @FromEt = ?, @ToEt = ?"
    party_sql = ("EXEC Quality.Reject_GetPartMatrixByParty @ItemId = ?, "
                 "@FromEt = ?, @ToEt = ?")
    defect_sql = ("EXEC Quality.Reject_GetPartMatrixDefects @ItemId = ?, "
                  "@FromEt = ?, @ToEt = ?")

    parent_cols = [
        (250, "@ItemPartNumber@",       "left",  True),
        (170, "@ItemDescription@",      "left",  False),
        ( 60, "@TotalRejects@",         "right", True),
        ( 60, "@TotalNonRejectScrap@",  "right", False),
    ]
    party_cols = [
        ("Department", 150, "@ChargeToPartyName@", None,    "left"),
        ("Good pcs",    90, "@GoodPieces@",        NUM_FMT, "right"),
        ("Reject",      70, "@RejectPieces@",      NUM_FMT, "right"),
        ("Reject %",    70, "@RejectPercent@",     PCT_FMT, "right"),
    ]
    defect_cols = [
        ("Charge to",   80, "@ChargeToPartyCode@", None,    "left"),
        ("Code",        44, "@DefectCode@",        None,    "left"),
        ("Defect",     216, "@DefectDescription@", None,    "left"),
        ("Qty",         60, "@Quantity@",          NUM_FMT, "right"),
    ]
    layout = "".join([
        L.doc_open(), L.page_open(),
        title_block("Rejects - Part Matrix",
                    "@StartDate@ - @EndDate@" + L.esc("  |  per part: department split and defect detail")),
        L.text(36, 122, 540, 12,
               L.esc("Totals exclude non-reject scrap, which is shown separately."),
               size=8.5, italic=True, color=MUTED),
        nested_table(36, 140, 540, "Parts", parent_cols,
                     [("ByParty", party_cols),
                      ("Defects", defect_cols)]),
        L.page_close(), L.doc_close(),
    ])
    write("Rejects Part Matrix", "Rejects Part Matrix", DATE_PARAMS, [], layout,
          nested=("Parts", root_sql, ["{StartDate}", "{EndDate}"],
                  [("ByParty", party_sql, ["{ItemId}", "{StartDate}", "{EndDate}"]),
                   ("Defects", defect_sql, ["{ItemId}", "{StartDate}", "{EndDate}"])]))


# ---------------------------------------------------------------------------
# 4. Hold Status
# ---------------------------------------------------------------------------
def build_hold_status():
    sql = "EXEC Quality.Hold_ListOpenForReport @HoldTypeCodeId = NULL"
    cols = [
        ("Kind",        56, "@SubjectKind@",         None,    "left"),
        ("LOT / Cont.", 96, "@SubjectName@",         None,    "left"),
        ("Part",       104, "@ItemPartNumber@",      None,    "left"),
        ("Pcs",         40, "@LotPieceCount@",       NUM_FMT, "right"),
        ("Location",    88, "@CurrentLocationName@", None,    "left"),
        ("Hold type",   68, "@HoldTypeName@",        None,    "left"),
        ("Placed",      60, "@PlacedAt@",            DATE_FMT, "left"),
        ("Hours",       28, "@HoursOnHold@",         NUM_FMT, "right"),
    ]
    # Param-less reports must still declare ONE parameter: the Report Viewer
    # rejects an empty params dict.
    layout = "".join([
        L.doc_open(), L.page_open(),
        title_block("Hold Status",
                    L.esc("Every LOT and container currently on hold, oldest first")),
        L.table(36, 126, 540, "Holds", cols, HEAD_TXT, BODY),
        L.page_close(), L.doc_close(),
    ])
    write("Hold Status", "Hold Status",
          [("MinHours", "Integer", "0")],
          [("Holds", sql, [])], layout)


# ---------------------------------------------------------------------------
# 5. Shipping History
# ---------------------------------------------------------------------------
def build_shipping_history():
    sql = ("EXEC Lots.Container_ListShipped @FromEt = ?, @ToEt = ?, "
           "@PartNumberLike = NULL")
    cols = [
        ("Container",   64, "@ContainerId@",         None,    "left"),
        ("Part",       120, "@ItemPartNumber@",      None,    "left"),
        ("AIM shipper",132, "@AimShipperId@",        None,    "left"),
        ("Pcs",         48, "@PieceCount@",          NUM_FMT, "right"),
        ("Source LOTs", 60, "@SourceLotCount@",      NUM_FMT, "right"),
        ("Completed",   84, "@CompletedAt@",         DTM_FMT, "left"),
    ]
    # "Completed" is container CLOSE time. There is no ship timestamp in the
    # schema and no integration that would supply one, so the note states the
    # semantics on the page rather than letting a reader infer truck departure.
    note = ("Dated by container closure. The MES holds no shipping-system "
            "integration, so closure time is the latest point it can observe.")
    layout = "".join([
        L.doc_open(), L.page_open(),
        title_block("Shipping History",
                    "@StartDate@ - @EndDate@" + L.esc("  |  shipped containers")),
        L.text(36, 122, 540, 12, L.esc(note), size=8.5, italic=True, color=MUTED),
        L.table(36, 140, 540, "Shipped", cols, HEAD_TXT, BODY),
        L.page_close(), L.doc_close(),
    ])
    write("Shipping History", "Shipping History", DATE_PARAMS,
          [("Shipped", sql, ["{StartDate}", "{EndDate}"])], layout)


if __name__ == "__main__":
    print("Building aggregate reports from donor:", os.path.basename(os.path.dirname(DONOR)))
    build_rejects_detail()
    build_rejects_summary()
    build_rejects_matrix()
    build_hold_status()
    build_shipping_history()
    print("done -- 5 reports")
