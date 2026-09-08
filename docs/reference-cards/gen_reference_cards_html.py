# -*- coding: utf-8 -*-
"""Rewrite the sheets block of `reference-cards.src.html` from cards_content.

The HTML file keeps its hand-authored head: the token/CSS block and the
`.screen-only` print instructions above the first sheet are edited by hand
and are NOT touched here. Everything from the `SHEET 1` marker to the end of
the file is generated, so the published artifact and the printed PDF are
driven by the same copy.

Run after editing `cards_content.py`:
    python gen_reference_cards_html.py && python gen_reference_cards_pdf.py
"""
import io
import re

from cards_content import CARDS, SIGN_IN, DOWNTIME, HELP

SRC = "reference-cards.src.html"
MARKER = "<!-- ======================= SHEET 1 ======================= -->"

FOOT = """    <div class="card-foot">
      <div class="foot-block">
        <span class="label">Start &middot; Sign In</span>
        <span class="body">%s</span>
      </div>
      <div class="foot-help">
        <span class="q-badge">?</span>
        <span class="body">%s</span>
      </div>
      <div class="foot-block">
        <span class="label">Downtime</span>
        <span class="body">%s</span>
      </div>
    </div>""" % (SIGN_IN, HELP, DOWNTIME)

PLACEHOLDER = """  <div class="card" style="border-style: dashed; align-items: center; justify-content: center;">
    <div style="display:flex; flex-direction:column; align-items:center; justify-content:center; height:100%; gap:8px; color: var(--ink-muted);">
      <span style="font-family: var(--font-display); font-weight:700; font-size:15px; letter-spacing:0.08em; text-transform:uppercase;">Room for one more</span>
      <span style="font-size:12.5px; max-width: 4in; text-align:center; line-height:1.4;">Add a card here for the next terminal type, or leave this half blank on the printed sheet.</span>
    </div>
  </div>"""


def render_head(card):
    """Header band: station, hairline divider, tab name (option A)."""
    if card.get("sub"):
        title = ('<span class="head-row"><span class="station">%s</span>'
                 '<span class="head-div"></span>'
                 '<span class="substation">%s</span></span>'
                 % (card["station"], card["sub"]))
    else:
        title = '<span class="station">%s</span>' % card["station"]
    return ('    <div class="card-head">\n      %s\n'
            '      <span class="tag">%s</span>\n    </div>'
            % (title, card["tag"]))


def render_card(card):
    steps = "\n".join(
        '        <li><span class="num">%d</span><span class="txt">%s</span></li>'
        % (i, s) for i, s in enumerate(card["steps"], 1))
    body = ['    <div class="card-body">',
            '      <div class="run-label">Run the screen</div>',
            '      <ul class="steps">', steps, '      </ul>']
    if card.get("rail"):
        label, text = card["rail"]
        body.append('      <div class="rail-box">\n'
                    '        <div class="rail-label">%s</div>\n'
                    '        <div class="rail-body">%s</div>\n'
                    '      </div>' % (label, text))
    if card.get("note"):
        body.append('      <div class="card-note">%s</div>' % card["note"])
    body.append('    </div>')
    return ('  <div class="card">\n%s\n%s\n%s\n  </div>'
            % (render_head(card), "\n".join(body), FOOT))


def build():
    src = io.open(SRC, encoding="utf-8").read()
    head = src[:src.index(MARKER)]

    # Two cards to a Letter sheet, cut-line between; a lone trailing card is
    # paired with the placeholder half rather than printing a ragged sheet.
    pairs = [CARDS[i:i + 2] for i in range(0, len(CARDS), 2)]
    total = len(pairs)
    out = []
    for n, pair in enumerate(pairs, 1):
        second = render_card(pair[1]) if len(pair) > 1 else PLACEHOLDER
        out.append(
            "<!-- ======================= SHEET %d ======================= -->\n"
            '<div class="sheet-label">Sheet %d of %d</div>\n'
            '<div class="sheet">\n\n%s\n\n  <div class="cut-line"></div>\n\n%s\n\n</div>'
            % (n, n, total, render_card(pair[0]), second))

    io.open(SRC, "w", encoding="utf-8").write(head + "\n\n".join(out) + "\n")
    print("rewrote %s: %d cards across %d sheets" % (SRC, len(CARDS), total))


if __name__ == "__main__":
    build()
