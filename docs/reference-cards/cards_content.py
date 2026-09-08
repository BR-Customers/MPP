# -*- coding: utf-8 -*-
"""Single source of truth for the shop-floor reference card copy.

Both generators import from here - `gen_reference_cards_pdf.py` (the
print-ready PDF) and `gen_reference_cards_html.py` (which rewrites the
sheets block of `reference-cards.src.html`). Edit the copy in this file
only; regenerate both afterwards. Before this module the same text lived
twice, hand-maintained, in the PDF generator's CARDS list and in the HTML
source - eleven cards made that untenable.

Markup in the strings is the small subset both renderers understand:
`<b>` for bold, and the HTML entities listed in `ENTITIES` below (reportlab
speaks its own mini-HTML, so entities are pre-substituted for the PDF).

Card shape:
    station : the terminal / area name - big, left of the header band
    sub     : the tab or mode within that screen (None on single-mode cards)
    tag     : the pill on the right of the header band
    steps   : numbered "Run the screen" list
    note    : optional warn-tinted callout under the steps
    rail    : optional accent-tinted callout - used where the card has room
              and the screen has persistent chrome worth pointing at
"""

# Entities used in the copy, and their PDF (reportlab) equivalents. Kept
# explicit rather than relying on a general HTML unescape so that adding a
# new entity to the copy fails loudly in review instead of silently
# rendering as literal text on the printed card.
ENTITIES = {
    "&ndash;": u"–",
    "&middot;": u"·",
    "&rsquo;": u"’",
    "&ldquo;": u"“",
    "&rdquo;": u"”",
}


def for_pdf(text):
    """Convert the shared copy's entities to literal characters for reportlab."""
    for ent, char in ENTITIES.items():
        text = text.replace(ent, char)
    return text


# --------------------------------------------------------------- footer --
# The footer strip repeats on every card. Keep SIGN_IN short: the PDF draws
# the footer into a FIXED 1.05in box and does not grow it, so text that runs
# past ~5 lines at 8.4pt is silently clipped on the printed card with nothing
# on screen to warn us. It currently sets 3 lines in the PDF (HTML, which
# does grow the strip, renders it at 115px). Re-render and eyeball the PDF
# footer before lengthening this.
SIGN_IN = (
    "Type your 5-digit <b>PIN</b>. Wrong digit? <b>Re-type PIN</b>. "
    # <br/> not <br>: reportlab's paraparser rejects the unclosed form,
    # and the self-closing spelling is valid HTML too.
    "<b>Register New User</b> is first-time only.<br/>"
    "Wrong name up top? Tap <b>Operator:</b> to switch."
)
DOWNTIME = "Machine down or waiting on something? Press <b>Downtime</b> up top."
HELP = ("Tap the <b>?</b> in the corner of any screen for step-by-step help "
        "on that exact screen.")

# ---------------------------------------------------------------- cards --
CARDS = [
    dict(
        station="Die Cast", sub="Open Basket", tag="One basket per cavity",
        steps=[
            "Check the <b>Die</b> box names the tool actually mounted on this "
            "machine &ndash; the cavity rows below come from it.",
            "On each cavity row, pick the <b>Part</b>. Every cavity running the "
            "same part? Press <b>Copy part to empty rows</b>.",
            "Scan the <b>LTT Barcode</b> from the basket into that row.",
            "Press <b>OPEN BASKETS</b> to open every row you filled in.",
        ],
        note="<b>If the die is wrong or empty</b> &ndash; stop and tell a "
             "supervisor. Do not work around it.",
    ),
    dict(
        station="Die Cast", sub="Record Shift Output",
        tag="Shots &middot; Scrap &middot; Submit",
        steps=[
            "Pick your <b>Reporting shift</b>.",
            "Enter <b>Shots this entry</b> &ndash; that is die-wide, not per cavity.",
            "Press <b>Compute / Preview</b> to break it down by cavity.",
            "Press <b>Add scrap reason</b> on any cavity that had scrap. "
            "<b>Good (pc)</b> updates on its own as you log it.",
            "Lost a whole shot? Pick a reason and qty under <b>Shot loss (all "
            "cavities)</b> and press <b>Register shot loss</b> before you submit.",
            "Press <b>SUBMIT SHIFT OUTPUT</b> when the rows look right.",
        ],
    ),
    dict(
        station="Die Cast", sub="Lot Release", tag="Release &middot; Void",
        steps=[
            "<b>Release</b> &ndash; press it on a basket that is full. It leaves "
            "the cavity, moves on to its next step, and frees the cavity for a "
            "new basket.",
            "<b>Void</b> &ndash; only shows on an empty basket. It discards that "
            "basket.",
        ],
        rail=("Watch the right-hand rail",
              "<b>Shots this shift</b> &middot; <b>Good parts this shift</b> "
              "&middot; <b>Scrap this shift</b> &middot; <b>Die total shots</b> "
              "(count / limit). If it reads <b>Approaching shot limit</b> or "
              "<b>OVER SHOT LIMIT</b>, tell a supervisor before you open the "
              "next basket."),
    ),
    dict(
        station="Trim", sub="Check IN", tag="Scan &middot; Move",
        steps=[
            "If this press is shared, pick it from the <b>cell picker</b> at the "
            "top of the screen first.",
            "Scan the <b>LTT</b> &ndash; the LOT, item, and eligibility show up "
            "for you to check.",
            "Press <b>Move</b> to commit it to this cell.",
        ],
    ),
    dict(
        station="Trim", sub="Trim OUT",
        tag="Count &middot; Scrap &middot; Release",
        steps=[
            "Tap the LOT&rsquo;s card in the <b>Trim inventory</b> list, or scan "
            "its <b>LTT Barcode</b>.",
            "Enter the <b>Lot count</b>.",
            "Tap a reason under <b>Scrap reasons</b> to add one piece. Press "
            "<b>More reasons</b> if the one you need is not on the short list.",
            "Press <b>Trim OUT</b> to release the LOT out of Trim.",
        ],
        note="<b>Trim OUT always moves the whole LOT together</b> &ndash; there "
             "is no split here.",
    ),
    dict(
        station="Machining IN", sub=None, tag="Scan &middot; Confirm",
        steps=[
            "Scan the LTT on the casting you picked up.",
            "Check the LOT, item, and piece count shown are the right ones.",
            "Press <b>Start Machining</b>. It moves onto <b>Active machined LOT</b> "
            "below.",
        ],
    ),
    dict(
        station="Machining OUT", sub=None, tag="Mint from the queue",
        steps=[
            "The oldest casting is already selected. Tap <b>Select</b> only to "
            "work a different one.",
            "Enter how many <b>Pieces</b> to mint &ndash; it pulls from the whole "
            "queue, not just one casting.",
            "Add scrap lines if any, then press <b>Submit</b>.",
        ],
    ),
    dict(
        station="Assembly IN", sub=None, tag="Scan components",
        steps=[
            "Scan or enter the LTT on the machined component.",
            "Press <b>Scan In</b>. It is added to <b>Components at this cell</b> "
            "below.",
        ],
    ),
    dict(
        station="Assembly", sub="Non-Serialized", tag="Fill &middot; Complete",
        steps=[
            "Check <b>Now producing</b> and the components staged at this cell.",
            "<b>By Count</b> lines: enter the count and press <b>Complete Tray</b> "
            "when full. <b>By Weight / By Vision</b>: the scale or camera closes "
            "it &ndash; nothing to press.",
            "On a By Count line, once enough trays are in, press <b>Complete</b> "
            "under <b>Container Completion Gate</b>.",
        ],
        note="A single-tray container ships on its own &ndash; you will not see "
             "the gate for it.",
    ),
    dict(
        station="Assembly", sub="Serialized", tag="Watch &middot; Complete",
        steps=[
            "This line is MIP-integrated &ndash; watch <b>Current Tray</b>. It "
            "closes on its own; nothing to press per piece.",
            "Once enough trays are in, press <b>Complete</b> under <b>WorkOrder "
            "Completion Gate</b> to finish and ship it.",
        ],
        note="A failed AIM post shows a warning and retries on its own &ndash; no "
             "action needed from you.",
    ),
    dict(
        station="Downtime", sub="Downtime Entry",
        tag="Start &middot; Reason &middot; End",
        steps=[
            "Check the <b>Machine</b> box at the top is the one that stopped; pick "
            "it from the list if not.",
            "Press <b>Start Downtime</b> as soon as it stops &ndash; do not wait "
            "until you know why. It opens with no reason.",
            "Pick the <b>Reason</b> on the row once you know it.",
            "Press <b>End</b> on the row when work resumes. No supervisor sign-in "
            "needed.",
        ],
        note="<b>Add Past Event</b> logs downtime you missed. <b>Edit</b> and "
             "<b>Void</b> both ask for a supervisor sign-in &ndash; Void is "
             "permanent.",
    ),
]
