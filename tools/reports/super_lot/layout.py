"""ReportMill page layout for the Super-lot report (mock 7: member summary only,
no per-member event history).

Generated rather than hand-written XML because the tables are repetitive; the
output of `build()` is what goes into data.bin. Style matches the Lot Detail
report (Helvetica, ink masthead, cyan rule) so the two sit in the same suite.

Pages (ReportMill repeats a WHOLE page when one of its tables overflows, so an
unbounded table gets a page of its own):
  1. Header + key/values, Results by outcome | Scrap by defect code (side by side;
     both are short: five dispositions at most, a handful of defect codes).
  2. Members -- one row per membership; unbounded.
  3. Deviations (top box) + Signatures (bottom box).

Rules that fail SILENTLY when broken (see ignition-context-pack/10_reporting_module.md):
  * every literal goes through esc(); only @tokens@ are passed raw;
  * <format> uses pattern=, never format=;
  * <tablerow title> is exactly "<list-key> Header|Details";
  * no nested tables here, so no <table-group> is needed.
All text is ASCII; the middle dot is the XML character reference &#183;.
"""

INK = "#0B1220"
ACCENT = "#1888A8"
ACCENT_DK = "#126680"
HEAD_TXT = "#F0F3F8"
SUB_TXT = "#9AA8BF"
COL_HEAD = "#1F2C44"
BODY = "#1b2430"
MUTED = "#6b788f"
RULE = "#dfe4ea"
FONT = "Helvetica"
DOT = "  &#183;  "

DTM = '<format type="date" pattern="MM/dd/yyyy  HH:mm" null-string="-"/>'
NUM = '<format type="number" pattern="#,##0" null-string="-"/>'


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, w, h, s, size=9, bold=False, color=BODY, align=None, fmt=None):
    out = ['<text x="%s" y="%s" width="%s" height="%s">' % (x, y, w, h),
           '<font logical_name="%s" style="%d" size="%s"/>' % (FONT, 1 if bold else 0, size),
           '<color value="%s"/>' % color]
    if align:
        out.append('<pgraph align="%s"/>' % align)
    out.append('<string>%s</string>' % s)
    if fmt:
        out.append(fmt)
    out.append('</text>')
    return "".join(out)


def rect(x, y, w, h, color):
    return ('<rect x="%s" y="%s" width="%s" height="%s" useFill="true">'
            '<stroke/><fill color="%s"/></rect>' % (x, y, w, h, color))


def footer():
    return (text(36, 762, 330, 16, "Super-lot @Header.RunNumber@" + DOT + "Page  @Page@  of  @PageMax@",
                 color=MUTED)
            + text(376, 762, 200, 16, esc("All times Eastern"), color=MUTED, align="right"))


def section_head(y, title):
    return (rect(36, y + 1, 4, 16, ACCENT)
            + text(48, y, 480, 18, title, size=12, bold=True, color=ACCENT_DK))


def small_masthead(title):
    return (rect(36, 40, 540, 30, INK) + rect(36, 70, 540, 3, ACCENT)
            + text(50, 46, 512, 20, esc(title), size=15, bold=True, color=HEAD_TXT)
            + text(50, 78, 512, 14,
                   "Super-lot @Header.RunNumber@" + DOT + "@Header.Reason@", color=MUTED))


def table(x, y, w, h, key, cols, row_h=17, head_h=20, size=9):
    """cols: (label, width, cell_string, align, fmt). cell_string may mix
    literals (already escaped) and bare @column@ tokens."""
    total = sum(c[1] for c in cols)
    p = ['<table x="%d" y="%d" width="%d" height="%d" list-key="%s">' % (x, y, w, h, key),
         '<grouping key="%s" header="true" details="true"/>' % key,
         '<tablerow width="%d" height="%d" title="%s Header">' % (total, head_h, key)]
    cx = 0
    for (label, cw, cell, align, fmt) in cols:
        p.append('<row-cell-text x="%d" width="%d" height="%d">'
                 '<font logical_name="%s" style="1" size="%s"/><color value="%s"/>'
                 '<pgraph align="%s"/><string>%s</string></row-cell-text>'
                 % (cx, cw, head_h, FONT, size, COL_HEAD, align, esc(label)))
        cx += cw
    p.append('</tablerow>')
    p.append('<tablerow y="%d" width="%d" height="%d" title="%s Details">' % (head_h, total, row_h, key))
    cx = 0
    for (label, cw, cell, align, fmt) in cols:
        p.append('<row-cell-text x="%d" width="%d" height="%d">'
                 '<font logical_name="%s" style="0" size="%s"/><color value="%s"/>'
                 '<pgraph align="%s"/><string>%s</string>%s</row-cell-text>'
                 % (cx, cw, row_h, FONT, size, BODY, align, cell, fmt or ""))
        cx += cw
    p.append('</tablerow>')
    p.append('</table>')
    return "".join(p)


def kv(x, y, w, label, value, fmt=None, h=16):
    return (text(x, y, w, 12, esc(label.upper()), size=8, bold=True, color=MUTED)
            + text(x, y + 12, w, h, value, size=11, bold=True, fmt=fmt))


def page1():
    p = ['<page width="612" height="792">', footer(),
         rect(36, 40, 540, 70, INK), rect(36, 110, 540, 3, ACCENT),
         text(51, 47, 330, 12, "MADISON PRECISION PRODUCTS" + DOT + "MES" + DOT + "SUPER-LOT",
              size=8.5, bold=True, color=ACCENT),
         text(50, 60, 510, 30, "Super-lot @Header.RunNumber@", size=24, bold=True, color=HEAD_TXT),
         text(51, 90, 300, 18, esc("Controlled Run report"), size=13, color=SUB_TXT),
         # Print time from SQL, already Eastern (the footer says "All times Eastern").
         text(386, 47, 175, 12, esc("PRINTED"), size=8, bold=True, color=SUB_TXT, align="right"),
         text(386, 60, 175, 14, "@Printed.PrintedAt@", size=10, color=SUB_TXT, align="right", fmt=DTM)]
    L, R, W = 38, 316, 258
    y = 124
    p += [kv(L, y, W, "Status", "@Header.StatusCode@"),
          kv(R, y, W, "Pieces", "@Header.PieceCount@", fmt=NUM)]
    y += 34
    p += [kv(L, y, W, "Opened", "@Header.OpenedAt@", fmt=DTM),
          kv(R, y, W, "Opened by", "@Header.OpenedByInitials@")]
    y += 34
    p += [kv(L, y, W, "Closed", "@Header.ClosedAt@", fmt=DTM),
          kv(R, y, W, "Closed by", "@Header.ClosedByInitials@")]
    y += 34
    p += [kv(L, y, W, "Members", "@Header.MemberCount@  (@Header.ClearedCount@ cleared)"),
          kv(R, y, W, "Anchor LOT", "@Header.AnchorLotName@")]
    y += 34
    p += [kv(L, y, 536, "Reason", "@Header.Reason@", h=30)]
    y += 46
    p += [kv(L, y, 536, "Selection", "@Header.CriteriaText@", h=30)]
    y += 46
    p += [kv(L, y, 536, "Close remarks", "@Header.CloseRemarks@", h=30)]
    y += 50
    p.append(rect(36, y, 540, 1, RULE))
    y += 12
    p.append(section_head(y, esc("Results by outcome")))
    p.append(rect(316, y + 1, 4, 16, ACCENT))
    p.append(text(328, y, 248, 18, esc("Scrap by defect code"), size=12, bold=True, color=ACCENT_DK))
    y += 24
    h = 732 - y
    p.append(table(36, y, 260, h, "Outcomes",
                   [("Outcome", 180, "@Label@", "left", None),
                    ("Pieces", 80, "@Pieces@", "right", NUM)]))
    p.append(table(316, y, 260, h, "Defects",
                   [("Defect", 180, "@Label@", "left", None),
                    ("Pieces", 80, "@Pieces@", "right", NUM)]))
    p.append('</page>')
    return "".join(p)


def page2():
    p = ['<page x="712" width="612" height="792">', footer(), small_masthead("Members")]
    p.append(text(50, 92, 512, 12,
                  esc("One row per membership, in the order they joined. Removed members are listed with how they left."),
                  size=8, color=MUTED))
    p.append(table(36, 110, 540, 622, "Members",
                   [("Member", 86, "@MemberName@", "left", None),
                    ("Part", 84, "@PartNumber@", "left", None),
                    ("Pcs", 36, "@PieceCount@", "right", NUM),
                    ("Joined", 70, "@JoinedText@", "left", None),
                    ("Left", 70, "@LeftText@", "left", None),
                    ("Accepted", 46, "@AcceptedQty@", "right", NUM),
                    ("Scrap", 36, "@ScrapQty@", "right", NUM),
                    ("Other", 112, "@OtherText@", "left", None)],
                   row_h=22, size=8))
    p.append('</page>')
    return "".join(p)


def page3():
    p = ['<page x="1424" width="612" height="792">', footer(),
         small_masthead("Deviations and signatures")]
    p.append(section_head(96, esc("Deviations")))
    p.append(table(36, 120, 540, 250, "Deviations",
                   [("Deviation", 66, "@DeviationNumber@", "left", None),
                    ("Defect", 50, "@DefectCode@", "left", None),
                    ("Qty", 36, "@AffectedQuantity@", "right", NUM),
                    ("Description", 238, "@Description@", "left", None),
                    ("Raised", 90, "@RaisedAt@", "left", DTM),
                    ("By", 60, "@SignedByInitials@", "left", None)],
                   row_h=30, size=8))
    p.append(section_head(384, esc("Signatures")))
    p.append(table(36, 408, 540, 324, "Signatures",
                   [("Signed", 90, "@SignedAt@", "left", DTM),
                    ("Meaning", 92, "@MeaningName@", "left", None),
                    ("By", 50, "@SignedByInitials@", "left", None),
                    ("What was signed", 308, "@Summary@ -- &quot;@Statement@&quot;", "left", None)],
                   row_h=36, size=8))
    p.append('</page>')
    return "".join(p)


def build():
    return "".join([
        '<?xml version="1.0" encoding="UTF-8"?>\n',
        '<document version="14" show-margin="true" snap-margin="true" '
        'margin="36 36 36 36" null-string="-">',
        page1(), page2(), page3(),
        '</document>'])
