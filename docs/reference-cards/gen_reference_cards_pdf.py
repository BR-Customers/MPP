# -*- coding: utf-8 -*-
"""Build the Shop Floor Reference Cards as an actual print-ready PDF.

No browser dependency (headless Chromium/Edge proved unreliable in this
environment) - pure reportlab. Structural elements (header bands, badges,
dividers, callout boxes) are drawn directly on the canvas; text content uses
reportlab.platypus.Paragraph for automatic wrapping, drawn at a fixed
position via wrapOn/drawOn. Content mirrors the published HTML artifact
(same 7 stations, same copy), reflowed for a vector PDF instead of CSS.
"""
import io
from reportlab.lib.pagesizes import letter
from reportlab.lib.colors import HexColor
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.enums import TA_LEFT, TA_CENTER
from reportlab.pdfgen import canvas
from reportlab.pdfbase.pdfmetrics import stringWidth
from reportlab.platypus import Paragraph

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

F_BOLD = "Helvetica-Bold"
F_REG  = "Helvetica"

PAGE_W, PAGE_H = letter
MARGIN = 0.4 * 72
CARD_W = 7.7 * 72
CARD_H = 5.05 * 72
GAP    = 0.22 * 72

SIGN_IN_BODY = (
    "Type your initials, press <b>Enter</b>. Not recognized? Press "
    "<b>Register New User</b>.<br/>Wrong name showing? Tap <b>Operator:</b> "
    "up top to switch."
)
DOWNTIME_BODY = (
    "Machine down or waiting on something? Press <b>Downtime</b> up top."
)
HELP_BODY = (
    "Tap the <b>?</b> in the corner of any screen for step-by-step help "
    "on that exact screen."
)

CARDS = [
    dict(
        station="Die Cast", tag="Open · Record · Release",
        steps=[
            "Check the <b>Die</b> box names the tool actually mounted on this machine.",
            "On <b>Open Basket</b>: pick the Part, scan the LTT, press <b>OPEN BASKETS</b>.",
            "On <b>Record Shift Output</b>: pick your shift, enter the shot count, "
            "<b>Compute / Preview</b>, log any scrap, <b>SUBMIT SHIFT OUTPUT</b>.",
            "On <b>Lot Release</b>: press <b>Release</b> on any basket that is full.",
        ],
        note="<b>If the die is wrong or empty</b> – stop and tell a supervisor. "
             "Do not work around it.",
    ),
    dict(
        station="Trim", tag="Check IN · Trim OUT",
        steps=[
            "If this press is shared, pick it from the top of the screen first.",
            "On <b>Check IN</b>: scan the LTT, review the LOT shown, press <b>Move</b>.",
            "On <b>Trim OUT</b>: tap the LOT’s card (or scan its LTT), enter the "
            "<b>Lot count</b>.",
            "Add scrap reasons if any, then press <b>Trim OUT</b> to release the whole LOT.",
        ],
    ),
    dict(
        station="Machining IN", tag="Scan · Confirm",
        steps=[
            "Scan the LTT on the casting you picked up.",
            "Check the LOT, item, and piece count shown are the right ones.",
            "Press <b>Start Machining</b>. It moves onto <b>Active machined LOT</b> below.",
        ],
    ),
    dict(
        station="Machining OUT", tag="Mint from the queue",
        steps=[
            "The oldest casting is already selected. Tap <b>Select</b> only to work a "
            "different one.",
            "Enter how many <b>Pieces</b> to mint – it pulls from the whole queue, "
            "not just one casting.",
            "Add scrap lines if any, then press <b>Submit</b>.",
        ],
    ),
    dict(
        station="Assembly IN", tag="Scan components",
        steps=[
            "Scan or enter the LTT on the machined component.",
            "Press <b>Scan In</b>. It is added to <b>Components at this cell</b> below.",
        ],
    ),
    dict(
        station="Assembly · Non-Serialized", tag="Fill · Complete",
        steps=[
            "Check <b>Now producing</b> and the components staged at this cell.",
            "<b>By Count</b> lines: enter the count and press <b>Complete Tray</b> when "
            "full. <b>By Weight / By Vision</b>: the scale or camera closes it – "
            "nothing to press.",
            "On a By Count line, once enough trays are in, press <b>Complete</b> under "
            "<b>Container Completion Gate</b>.",
        ],
        note="A single-tray container ships on its own – you will not see the gate "
             "for it.",
    ),
    dict(
        station="Assembly · Serialized", tag="Watch · Complete",
        steps=[
            "This line is MIP-integrated – watch <b>Current Tray</b>. It closes on "
            "its own; nothing to press per piece.",
            "Once enough trays are in, press <b>Complete</b> under <b>WorkOrder "
            "Completion Gate</b> to finish and ship it.",
        ],
        note="A failed AIM post shows a warning and retries on its own – no action "
             "needed from you.",
    ),
]

# ------------------------------------------------------------- paragraphs --
style_step = ParagraphStyle(
    "step", fontName=F_REG, fontSize=10.3, leading=13, textColor=INK)
style_note = ParagraphStyle(
    "note", fontName=F_REG, fontSize=8.8, leading=11.4, textColor=INK)
style_foot = ParagraphStyle(
    "foot", fontName=F_REG, fontSize=8.4, leading=10.6, textColor=INK)
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

    c.setFillColor(PAPER)
    c.setFont(F_BOLD, 19)
    c.drawString(x + 0.28 * 72, top - head_h + 0.16 * 72, data["station"])

    tag_font_size = 8.2
    tag_w = stringWidth(data["tag"], F_BOLD, tag_font_size) + 22
    tag_h = 16
    tag_x = x + CARD_W - 0.26 * 72 - tag_w
    tag_y = top - head_h / 2 - tag_h / 2
    c.setStrokeColor(HexColor("#5A6270"))
    c.setLineWidth(0.8)
    c.roundRect(tag_x, tag_y, tag_w, tag_h, tag_h / 2, stroke=1, fill=0)
    c.setFillColor(ACCENT)
    c.setFont(F_BOLD, tag_font_size)
    c.drawCentredString(tag_x + tag_w / 2, tag_y + tag_h / 2 - 3, data["tag"])

    # ---- Vertical budget, footer-up so the fixed-size blocks (footer,
    # note) claim their space first and the steps get whatever is left,
    # rather than the steps claiming space top-down and leaving a gap
    # above the footer on every shorter card. ----
    foot_h = 1.05 * 72
    foot_y = bottom
    has_note = bool(data.get("note"))
    note_h = 0.42 * 72
    note_gap = 0.08 * 72
    # Without a note, steps_bottom collapses to just above the footer (a
    # small breathing gap, not the full note box + gap) so the steps block
    # actually reclaims that space instead of centering in a shorter range
    # that still assumes a note is there.
    note_y = foot_y + foot_h + (note_h + note_gap if has_note else note_gap)

    body_top = top - head_h - 0.12 * 72
    body_left = x + 0.28 * 72
    body_w = CARD_W - 0.56 * 72

    c.setFillColor(ACCENT)
    c.setFont(F_BOLD, 8.6)
    c.drawString(body_left, body_top - 8, "RUN THE SCREEN")

    steps_top = body_top - 22
    steps_bottom = note_y  # steps must not encroach below the note's top
    num_d = 15
    text_x = body_left + num_d + 10
    text_w = body_w - num_d - 10

    # Pre-measure every step's wrapped height so the whole block can be
    # centered in the space actually available (matches the HTML version's
    # `justify-content: center` on .steps, instead of stacking from the top
    # and leaving a dead gap above the note on any card with few steps).
    step_gap = 7
    paras, heights = [], []
    for step_text in data["steps"]:
        p = Paragraph(step_text, style_step)
        _, h = p.wrapOn(c, text_w, 400)
        paras.append(p)
        heights.append(h)
    total_h = sum(heights) + step_gap * (len(heights) - 1)
    available = steps_top - steps_bottom
    cy = steps_top - max(0, (available - total_h) / 2)

    for i, (p, h) in enumerate(zip(paras, heights), start=1):
        cx = body_left + num_d / 2
        ccy = cy - 9
        c.setFillColor(ACCENT_SOFT)
        c.setStrokeColor(ACCENT_LINE)
        c.setLineWidth(1)
        c.circle(cx, ccy, num_d / 2, stroke=1, fill=1)
        c.setFillColor(ACCENT)
        c.setFont(F_BOLD, 8.6)
        c.drawCentredString(cx, ccy - 3, str(i))
        p.drawOn(c, text_x, cy - h)
        cy -= h + step_gap

    # ---- Callout note (only on cards that have one) ----
    if has_note:
        c.setFillColor(WARN_SOFT)
        c.rect(body_left, note_y - note_h, body_w, note_h, stroke=0, fill=1)
        c.setFillColor(WARN)
        c.rect(body_left, note_y - note_h, 2.6, note_h, stroke=0, fill=1)
        draw_para(c, data["note"], style_note, body_left + 10, note_y - 7,
                  body_w - 18, note_h - 6)

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
    c.setFont(F_BOLD, 8.2)
    c.drawString(col1_x + pad, foot_y + foot_h - 13, "START · SIGN IN")
    draw_para(c, SIGN_IN_BODY, style_foot, col1_x + pad, foot_y + foot_h - 20,
              col1_w - 2 * pad, foot_h - 22)

    c.setFillColor(INK_MUTED)
    c.setFont(F_BOLD, 8.2)
    c.drawString(col3_x + pad, foot_y + foot_h - 13, "DOWNTIME")
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
