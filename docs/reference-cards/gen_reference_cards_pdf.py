# -*- coding: utf-8 -*-
"""Build the Shop Floor Reference Cards as an actual print-ready PDF.

No browser dependency (headless Chromium/Edge proved unreliable in this
environment) - pure reportlab. Structural elements (header bands, badges,
dividers, callout boxes) are drawn directly on the canvas; text content uses
reportlab.platypus.Paragraph for automatic wrapping, drawn at a fixed
position via wrapOn/drawOn. Card copy is imported from `cards_content.py`,
which the HTML generator reads too - so the printed card and the published
artifact cannot drift apart.
"""
import io
from reportlab.lib.pagesizes import letter
from reportlab.lib.colors import HexColor
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.enums import TA_LEFT, TA_CENTER
from reportlab.pdfgen import canvas
from reportlab.pdfbase.pdfmetrics import stringWidth
from reportlab.platypus import Paragraph

from cards_content import CARDS, SIGN_IN, DOWNTIME, HELP, for_pdf

# ---------------------------------------------------------------- palette --
INK          = HexColor("#16181D")
INK_MUTED    = HexColor("#4B5563")
PAPER        = HexColor("#FFFFFF")
PAPER_SOFT   = HexColor("#F6F8F9")
LINE         = HexColor("#CBD5DB")
ACCENT       = HexColor("#0E7C99")
ACCENT_SOFT  = HexColor("#E3F3F7")
ACCENT_LINE  = HexColor("#BFE1EA")
WARN         = HexColor("#9A3412")
WARN_SOFT    = HexColor("#FBE9E1")
SUBSTATION   = HexColor("#C4CEDA")   # tab name on the dark header band
HEAD_DIV     = HexColor("#4A5260")   # hairline between station and tab

F_BOLD = "Helvetica-Bold"
F_REG  = "Helvetica"

PAGE_W, PAGE_H = letter
MARGIN = 0.4 * 72
CARD_W = 7.7 * 72
CARD_H = 5.05 * 72
GAP    = 0.22 * 72

SIGN_IN_BODY = for_pdf(SIGN_IN)
DOWNTIME_BODY = for_pdf(DOWNTIME)
HELP_BODY = for_pdf(HELP)

# ------------------------------------------------------------- paragraphs --
style_step = ParagraphStyle(
    "step", fontName=F_REG, fontSize=13.5, leading=17, textColor=INK)
style_note = ParagraphStyle(
    "note", fontName=F_REG, fontSize=11.5, leading=14.9, textColor=INK)
style_foot = ParagraphStyle(
    "foot", fontName=F_REG, fontSize=10, leading=12.6, textColor=INK)
style_rail = ParagraphStyle(
    "rail", fontName=F_REG, fontSize=11.5, leading=14.9, textColor=INK)
style_foot_label = ParagraphStyle(
    "footlabel", fontName=F_BOLD, fontSize=8.2, leading=10,
    textColor=INK_MUTED, tracking=0.6)


def draw_para(c, text, style, x, y, w, h_avail):
    """Draw a Paragraph within (x, y-h_avail) to (x+w, y), top-aligned.
    Returns the actual rendered height."""
    p = Paragraph(text, style)
    _, h = p.wrapOn(c, w, h_avail)
    p.drawOn(c, x, y - h)
    return h


def draw_card(c, x, y, data):
    """Draw one card with its top-left corner at (x, y).

    Everything opaque (header fill, footer tint, etc.) is drawn inside a
    clip region shaped exactly like the outer rounded-rect border, then the
    border stroke is drawn last on top - this is what actually produces
    clean rounded corners in reportlab. Filling a separately-hand-built
    "rounded on top only" path UNDER a stroked round-rect (the first cut)
    leaves a visible seam wherever the two paths' arcs don't land on
    identical pixels."""
    top = y
    bottom = y - CARD_H

    c.saveState()
    clip = c.beginPath()
    clip.roundRect(x, bottom, CARD_W, CARD_H, 7)
    c.clipPath(clip, stroke=0, fill=0)

    # ---- Header band ----
    head_h = 0.52 * 72
    c.setFillColor(INK)
    c.rect(x, top - head_h, CARD_W, head_h, stroke=0, fill=1)

    # Station reads big and stays scannable from across the aisle (how the
    # right card gets found on a rack); the tab name sits after a hairline in
    # a lighter grey so the two are legible as separate things rather than
    # one run-on title.
    head_base = top - head_h + 0.16 * 72
    head_x = x + 0.28 * 72
    station = for_pdf(data["station"])
    c.setFillColor(PAPER)
    c.setFont(F_BOLD, 19)
    c.drawString(head_x, head_base, station)

    sub = data.get("sub")
    if sub:
        div_x = head_x + stringWidth(station, F_BOLD, 19) + 11
        c.setStrokeColor(HEAD_DIV)
        c.setLineWidth(1)
        c.line(div_x, head_base - 2, div_x, head_base + 14)
        c.setFillColor(SUBSTATION)
        c.setFont(F_BOLD, 14.5)
        c.drawString(div_x + 11, head_base, for_pdf(sub))

    tag_font_size = 8.2
    tag_w = stringWidth(for_pdf(data["tag"]), F_BOLD, tag_font_size) + 22
    tag_h = 16
    tag_x = x + CARD_W - 0.26 * 72 - tag_w
    tag_y = top - head_h / 2 - tag_h / 2
    c.setStrokeColor(HexColor("#5A6270"))
    c.setLineWidth(0.8)
    c.roundRect(tag_x, tag_y, tag_w, tag_h, tag_h / 2, stroke=1, fill=0)
    c.setFillColor(ACCENT)
    c.setFont(F_BOLD, tag_font_size)
    c.drawCentredString(tag_x + tag_w / 2, tag_y + tag_h / 2 - 3,
                        for_pdf(data["tag"]))

    # ---- Vertical budget, footer-up so the fixed-size blocks (footer,
    # note) claim their space first and the steps get whatever is left,
    # rather than the steps claiming space top-down and leaving a gap
    # above the footer on every shorter card. ----
    foot_h = 1.25 * 72
    foot_y = bottom

    body_top = top - head_h - 0.12 * 72
    body_left = x + 0.28 * 72
    body_w = CARD_W - 0.56 * 72

    # Callout blocks (rail, then note) are measured against their real
    # wrapped text rather than assumed to be one fixed height - the copy in
    # cards_content.py is free to grow to two or three lines, and a fixed
    # box would silently clip it on the printed card with nothing on screen
    # to warn us. Each still claims a minimum so short callouts do not look
    # cramped.
    block_gap = 0.08 * 72
    blocks = []          # bottom-up: (kind, height, payload)
    if data.get("rail"):
        rail_label, rail_body = data["rail"]
        rp = Paragraph(for_pdf(rail_body), style_rail)
        _, rh = rp.wrapOn(c, body_w - 20, 200)
        blocks.append(("rail", max(0.44 * 72, rh + 22),
                       (for_pdf(rail_label), rp, rh)))
    if data.get("note"):
        np_ = Paragraph(for_pdf(data["note"]), style_note)
        _, nh = np_.wrapOn(c, body_w - 18, 200)
        blocks.append(("note", max(0.42 * 72, nh + 12), np_))

    # Stack the callouts up from the footer. With no callout at all the
    # steps reclaim the space instead of centering in a range that still
    # assumes a box is sitting there.
    blocks_h = sum(h for _, h, _ in blocks) + block_gap * len(blocks)
    blocks_top = foot_y + foot_h + (blocks_h if blocks else block_gap)

    c.setFillColor(ACCENT)
    c.setFont(F_BOLD, 8.6)
    c.drawString(body_left, body_top - 8, "RUN THE SCREEN")

    steps_top = body_top - 22
    steps_bottom = blocks_top  # steps stop above the callout stack
    num_d = 19
    text_x = body_left + num_d + 10
    text_w = body_w - num_d - 10

    # Pre-measure every step's wrapped height so the whole block can be
    # centered in the space actually available (matches the HTML version's
    # `justify-content: center` on .steps, instead of stacking from the top
    # and leaving a dead gap above the note on any card with few steps).
    step_gap = 7
    paras, heights = [], []
    for step_text in data["steps"]:
        p = Paragraph(for_pdf(step_text), style_step)
        _, h = p.wrapOn(c, text_w, 400)
        paras.append(p)
        heights.append(h)
    total_h = sum(heights) + step_gap * (len(heights) - 1)
    available = steps_top - steps_bottom
    cy = steps_top - max(0, (available - total_h) / 2)

    for i, (p, h) in enumerate(zip(paras, heights), start=1):
        cx = body_left + num_d / 2
        # Centre the badge on the step's FIRST line, not on the whole
        # paragraph - a two-line step would otherwise sit its number low.
        ccy = cy - style_step.leading * 0.69
        c.setFillColor(ACCENT_SOFT)
        c.setStrokeColor(ACCENT_LINE)
        c.setLineWidth(1)
        c.circle(cx, ccy, num_d / 2, stroke=1, fill=1)
        c.setFillColor(ACCENT)
        c.setFont(F_BOLD, 10.5)
        c.drawCentredString(cx, ccy - 3.7, str(i))
        p.drawOn(c, text_x, cy - h)
        cy -= h + step_gap

    # ---- Callout blocks, drawn top-down from the top of the stack ----
    by = blocks_top
    for kind, bh, payload in blocks:
        if kind == "rail":
            label, rp, rh = payload
            c.setFillColor(ACCENT_SOFT)
            c.setStrokeColor(ACCENT_LINE)
            c.setLineWidth(1)
            c.roundRect(body_left, by - bh, body_w, bh, 3, stroke=1, fill=1)
            c.setFillColor(ACCENT)
            c.setFont(F_BOLD, 8.2)
            c.drawString(body_left + 10, by - 12, label.upper())
            rp.drawOn(c, body_left + 10, by - 16 - rh)
        else:
            c.setFillColor(WARN_SOFT)
            c.rect(body_left, by - bh, body_w, bh, stroke=0, fill=1)
            c.setFillColor(WARN)
            c.rect(body_left, by - bh, 2.6, bh, stroke=0, fill=1)
            payload.drawOn(c, body_left + 10, by - (bh + payload.height) / 2)
        by -= bh + block_gap

    # ---- Footer strip ----
    c.setStrokeColor(INK)
    c.setLineWidth(1.3)
    c.line(x, foot_y + foot_h, x + CARD_W, foot_y + foot_h)
    c.setFillColor(PAPER_SOFT)
    c.rect(x + 1, foot_y + 1, CARD_W - 2, foot_h - 2, stroke=0, fill=1)

    col1_w = CARD_W * 0.365
    col3_w = CARD_W * 0.365
    col2_w = CARD_W - col1_w - col3_w
    col1_x = x
    col2_x = x + col1_w
    col3_x = x + col1_w + col2_w

    c.setFillColor(ACCENT_SOFT)
    c.rect(col2_x, foot_y, col2_w, foot_h, stroke=0, fill=1)
    c.setStrokeColor(LINE)
    c.setLineWidth(1)
    c.line(col2_x, foot_y, col2_x, foot_y + foot_h)
    c.line(col2_x + col2_w, foot_y, col2_x + col2_w, foot_y + foot_h)

    pad = 10
    c.setFillColor(INK_MUTED)
    c.setFont(F_BOLD, 9.5)
    c.drawString(col1_x + pad, foot_y + foot_h - 14, "START · SIGN IN")
    draw_para(c, SIGN_IN_BODY, style_foot, col1_x + pad, foot_y + foot_h - 20,
              col1_w - 2 * pad, foot_h - 22)

    c.setFillColor(INK_MUTED)
    c.setFont(F_BOLD, 9.5)
    c.drawString(col3_x + pad, foot_y + foot_h - 14, "DOWNTIME")
    draw_para(c, DOWNTIME_BODY, style_foot, col3_x + pad, foot_y + foot_h - 20,
              col3_w - 2 * pad, foot_h - 22)

    badge_d = 30
    badge_cx = col2_x + pad + badge_d / 2
    badge_cy = foot_y + foot_h / 2
    c.setFillColor(PAPER)
    c.setStrokeColor(ACCENT)
    c.setLineWidth(2.2)
    c.circle(badge_cx, badge_cy, badge_d / 2, stroke=1, fill=1)
    c.setFillColor(ACCENT)
    c.setFont(F_BOLD, 15)
    c.drawCentredString(badge_cx, badge_cy - 5, "?")

    help_text_x = col2_x + pad + badge_d + 8
    help_text_w = col2_w - pad - badge_d - 8 - pad
    p = Paragraph(HELP_BODY, style_foot)
    _, h = p.wrapOn(c, help_text_w, foot_h)
    p.drawOn(c, help_text_x, badge_cy - h / 2)

    c.restoreState()

    # Border stroke drawn LAST, unclipped, on top of everything - this is
    # what actually produces a clean rounded-corner edge (see the docstring
    # above on why filling under a separately-built rounded path leaves a
    # seam).
    c.setStrokeColor(INK)
    c.setLineWidth(1.3)
    c.roundRect(x, bottom, CARD_W, CARD_H, 7, stroke=1, fill=0)


def draw_cut_line(c, x, y, w):
    c.setDash(3, 3)
    c.setStrokeColor(LINE)
    c.setLineWidth(1.2)
    c.line(x, y, x + w, y)
    c.setDash()
    label = "✁  cut here  ✁"
    fs = 7.5
    tw = stringWidth(label, F_BOLD, fs)
    c.setFillColor(PAPER)
    c.rect(x + w / 2 - tw / 2 - 6, y - 5, tw + 12, 10, stroke=0, fill=1)
    c.setFillColor(LINE)
    c.setFont(F_BOLD, fs)
    c.drawCentredString(x + w / 2, y - 3, label)


def draw_placeholder(c, x, y):
    c.setStrokeColor(LINE)
    c.setLineWidth(1.3)
    c.setDash(4, 3)
    c.roundRect(x, y - CARD_H, CARD_W, CARD_H, 7, stroke=1, fill=0)
    c.setDash()
    c.setFillColor(INK_MUTED)
    c.setFont(F_BOLD, 10.5)
    c.drawCentredString(x + CARD_W / 2, y - CARD_H / 2 + 10, "ROOM FOR ONE MORE")
    c.setFont(F_REG, 8.5)
    c.drawCentredString(x + CARD_W / 2, y - CARD_H / 2 - 6,
                         "Add a card here for the next terminal type, or leave")
    c.drawCentredString(x + CARD_W / 2, y - CARD_H / 2 - 18,
                         "this half blank on the printed sheet.")


def build(out_path):
    c = canvas.Canvas(out_path, pagesize=letter)
    c.setTitle("Shop Floor Reference Cards")
    pairs = [CARDS[i:i + 2] for i in range(0, len(CARDS), 2)]
    top_y = PAGE_H - MARGIN
    for page_idx, pair in enumerate(pairs):
        card1_y = top_y
        draw_card(c, MARGIN, card1_y, pair[0])
        cut_y = card1_y - CARD_H - GAP / 2
        draw_cut_line(c, MARGIN, cut_y, CARD_W)
        card2_y = card1_y - CARD_H - GAP
        if len(pair) > 1:
            draw_card(c, MARGIN, card2_y, pair[1])
        else:
            draw_placeholder(c, MARGIN, card2_y)
        c.showPage()
    c.save()


if __name__ == "__main__":
    build("Shop_Floor_Reference_Cards.pdf")
    print("done")
