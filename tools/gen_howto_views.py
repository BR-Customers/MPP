# -*- coding: utf-8 -*-
"""Generate the in-app "How To" popup views.

WHY A GENERATOR AT ALL. The guide body is one multi-kilobyte HTML string inside
a view.json. Hand-editing that is how you get an unclosed tag that swallows the
rest of the page and is invisible in a diff. Authoring it here means the content
is readable, the helpers enforce a consistent shape, and the escaping is applied
once on the way out.

MPP has no general view generator - views are file-authored JSON - so this is
scoped to the How To popups and nothing else. Re-running it rewrites only the
views it owns.

    python tools/gen_howto_views.py            # write the views
    python tools/gen_howto_views.py --check    # verify, write nothing

THE TWO TRAPS, both silent and total:
  1. The text goes in props.source. props.markdown is an options OBJECT; a
     string there renders nothing at all.
  2. escapeHtml defaults to True. With HTML in the source and the default left
     alone the operator reads `<div style="...">` on screen. The two settings
     only mean anything together.

HTML here renders through a plain HTML pipeline, NOT the Perspective layout
engine: flexbox and <style> blocks are not dependable. Structured content is
built the way an HTML email is - nested tables, every style inline, literal hex
colours rather than var(--mpp-*), which is not guaranteed to resolve outside
Perspective's own styling.
"""

import io
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MPP_VIEWS = os.path.join(
    REPO, "ignition", "projects", "MPP",
    "com.inductiveautomation.perspective", "views", "BlueRidge")
MPP_CONFIG_VIEWS = os.path.join(
    REPO, "ignition", "projects", "MPP_Config",
    "com.inductiveautomation.perspective", "views", "BlueRidge")

# Every guide names which Ignition project it belongs to (default "MPP" when
# a GUIDES entry omits it - see the get()s below) - both cross-file checks
# need it: which project tree to scan for openPopup calls, and which
# inheritance chain (project.json "parent") to resolve a viewPath against.
PROJECT_NAMES = ["MPP", "MPP_Config"]

# ---------------------------------------------------------------- palette ---
# Literal hex lifted from the plant-floor tokens in the Core stylesheet, so the
# guide reads as part of the app. Dark surface, light text - the plant floor is
# a dark theme, and a guide built on the usual light-background email palette
# would be unreadable here.
INK        = "#F0F3F8"   # --mpp-neutral-100, headings
BODY       = "#C9D2E0"   # --mpp-neutral-90,  body copy
MUTED      = "#9AA8BF"   # --mpp-neutral-80,  secondary
CARD       = "#172238"   # --mpp-neutral-30,  raised panel
ACCENT     = "#22A8CC"   # --mpp-accent-60,   step badge
ACCENT_INK = "#0B1220"   # --mpp-neutral-10,  text ON the accent badge
WARN_BG    = "#3A2E10"   # --mpp-cat-amber-bg
WARN_EDGE  = "#F4B343"   # --pf-status-warn-fg
INFO_BG    = "#093240"   # --mpp-accent-20
INFO_EDGE  = "#22A8CC"


def _step(n, title, body):
    """A numbered disc beside flowing text.

    A two-cell table row is the one layout that reliably puts a fixed-width
    badge next to wrapping text in this renderer.

    THE CARD ITSELF IS A <div>, NOT A <table> - only the badge/text columns
    inside it need a <table>. The component ships GitHub-flavoured-markdown
    table CSS scoped to `[data-component="ia.display.markdown"] table`:
    `tr { border-top: 1px solid #c6cbd1; background: #fff }` (zebra striping
    on even rows) AND, separately, `td, th { border: 1px solid #d0d7de }` -
    a border on every cell, all four sides, which is what draws a full box
    outline around a one-row layout (border-collapse merges the shared edges
    into a rectangle). None of it carries !important, and none of it applies
    to a plain <div> - a <table> element was ONLY ever needed here to line
    up the round badge against wrapping text, not to hold the card's
    background, so giving the background/radius/padding to a <div> instead
    sidesteps the whole rule family (including a leftover corner artifact
    the equivalent table-based card left behind, where border-radius on a
    <td> didn't fully clip the row underneath it). The inner table's own
    <tr>/<td> still need border:none + the card color, same reasoning as
    before, since that nested table's cells are independently in scope.
    Verified against the live component's computed styles + matched
    stylesheet rules 2026-08-31 - see
    feedback_ignition_markdown_table_bg_on_td.md."""
    tr = 'border:none;'
    td = 'border:none;'
    return (
        '<div style="background-color:%s;border-radius:6px;padding:14px;'
        'margin:0 0 12px 0;">'
        '<table width="100%%" cellpadding="0" cellspacing="0" border="0" '
        'style="border-collapse:collapse;"><tr style="%s">'
        '<td width="46" valign="top" style="%sbackground-color:%s;">'
        '<div style="width:34px;height:34px;border-radius:17px;'
        'background-color:%s;color:%s;font-size:17px;font-weight:bold;'
        'text-align:center;line-height:34px;">%s</div></td>'
        '<td valign="top" style="%sbackground-color:%s;padding-top:2px;">'
        '<div style="font-size:15px;font-weight:bold;color:%s;">%s</div>'
        '<div style="font-size:13.5px;color:%s;padding-top:3px;'
        'line-height:1.5;">%s</div>'
        '</td></tr></table>'
        '</div>'
    ) % (CARD, tr, td, CARD, ACCENT, ACCENT_INK, n, td, CARD, INK,
         title, BODY, body)


def _points(heading, items):
    """A set of independent facts/actions - NOT a sequence, so no numbered
    badges. One shared card, one table row per item (bullet + bold lead-in
    + description), so it reads as reference material rather than a
    workflow the operator works through in order.

    Same defensive pattern as _step(): every <tr>/<td> needs its own
    border:none + background-color, because the component's default
    GitHub-flavoured-markdown table CSS is scoped to EVERY table under it,
    not just ones that look like a numbered step - see _step()'s docstring
    for the full explanation (corner artifacts, forced white backgrounds,
    the works)."""
    tr = 'border:none;'
    td = 'border:none;'
    rows = []
    for title, body in items:
        rows.append(
            '<tr style="%s">'
            '<td width="18" valign="top" style="%sbackground-color:%s;'
            'color:%s;font-size:15px;font-weight:bold;padding-bottom:10px;">'
            '&bull;</td>'
            '<td valign="top" style="%sbackground-color:%s;padding-bottom:10px;">'
            '<span style="font-size:13.5px;font-weight:bold;color:%s;">%s'
            '</span><span style="font-size:13.5px;color:%s;line-height:1.5;">'
            ' &ndash; %s</span>'
            '</td></tr>'
            % (tr, td, CARD, ACCENT, td, CARD, INK, title, BODY, body))
    heading_html = ''
    if heading:
        heading_html = (
            '<div style="font-size:12px;font-weight:bold;letter-spacing:'
            '0.03em;text-transform:uppercase;color:%s;padding-bottom:8px;">'
            '%s</div>' % (MUTED, heading))
    return (
        '<div style="background-color:%s;border-radius:6px;padding:14px;'
        'margin:0 0 12px 0;">%s'
        '<table width="100%%" cellpadding="0" cellspacing="0" border="0" '
        'style="border-collapse:collapse;">%s</table>'
        '</div>'
    ) % (CARD, heading_html, ''.join(rows))


def _note(text):
    """A small aside for a secondary detail - not important enough for a
    boxed callout, but worth a beat of visual separation from the step body
    it follows."""
    return ('<div style="font-size:12.5px;color:%s;font-style:italic;'
            'padding:2px 0 14px 46px;line-height:1.5;">%s</div>') % (MUTED, text)


def _callout(bg, edge, heading, body):
    """A boxed aside. Colour carries the difference, not a louder heading.

    A plain <div>, not a <table> - no columns to line up here, so there is
    no reason to go anywhere near the component's default GFM table CSS
    (background/border forced onto every table/tr/td) at all. See _step()
    for the corner-artifact/border history this sidesteps."""
    return (
        '<div style="background-color:%s;border-left:5px solid %s;'
        'border-radius:4px;padding:12px 14px;margin:4px 0 16px 0;">'
        '<div style="font-size:14px;font-weight:bold;color:%s;'
        'padding-bottom:4px;">%s</div>'
        '<div style="font-size:13.5px;color:%s;line-height:1.5;">%s</div>'
        '</div>'
    ) % (bg, edge, INK, heading, BODY, body)


def _lead(text):
    return ('<div style="font-size:14.5px;color:%s;line-height:1.55;'
            'padding:0 0 16px 0;">%s</div>') % (BODY, text)


def _rule():
    return ('<div style="border-top:1px solid %s;margin:2px 0 16px 0;">'
            '</div>') % CARD


def _b(t):
    return '<span style="color:%s;font-weight:bold;">%s</span>' % (INK, t)


# ------------------------------------------------------------- die cast -----
# Written for the operator at the machine, not for whoever built the system.
# Order matches the screen: the die, then the three tabs left to right.
def diecast_source():
    parts = []
    parts.append(_lead(
        'Open a basket into each cavity, record what the die makes during your '
        'shift, then release the baskets when they are full.'))

    parts.append(_step(1, 'Check the die',
        'The %s box at the top names the tool mounted on this machine, and the '
        'cavity rows below come from it. If it is empty or names a different '
        'die, stop and tell a supervisor &ndash; do not work around it.'
        % _b('Die')))

    parts.append(_step(2, 'Open a basket into each cavity',
        'On %s, each row is one cavity. Pick the %s for the cavity, then scan '
        'the %s from the basket into that row. Press %s to open every row you '
        'filled in.'
        % (_b('Open Basket'), _b('Part'), _b('LTT Barcode'),
           _b('OPEN BASKETS'))))
    parts.append(_note(
        'If every cavity on this die runs the same part, %s fills the empty '
        'rows for you instead of picking the part on each one.'
        % _b('Copy part to empty rows')))

    parts.append(_step(3, 'Record what the die made',
        'On %s, choose your %s and enter the shot count. Press %s, then use '
        '%s on any cavity that had scrap &ndash; %s updates on its own as '
        'you log it. Press %s when the rows look right.'
        % (_b('Record Shift Output'), _b('Reporting shift'),
           _b('Compute / Preview'), _b('Add scrap reason'), _b('Good (pc)'),
           _b('SUBMIT SHIFT OUTPUT'))))

    parts.append(_step(4, 'Release the full baskets',
        'On %s, press %s on a basket that is full. It leaves the cavity, moves '
        'on to its next step, and frees the cavity for a new basket. %s only '
        'appears on an empty basket and discards it.'
        % (_b('Lot Release'), _b('Release'), _b('Void'))))

    parts.append(_rule())

    parts.append(_callout(INFO_BG, INFO_EDGE,
        'If a basket goes over its count',
        'The row shows %s and tells you how many pieces fit and how many '
        'overflow. Leave %s unchecked to release the basket at its limit '
        'and scan a new LTT for the extra pieces. Check it instead to keep '
        'everything in the one basket and carry on past the limit.'
        % (_b('Over basket headroom'), _b('Overfill this basket'))))

    return ''.join(parts)


# --------------------------------------------------------------- trim -------
# Verified against the live TrimBody view.json, not the older written guide -
# the guide still describes a destination picker that the terminal-mint
# redesign (2026-07-07) removed. Trim OUT is a whole-LOT move straight to
# this line's TRIM{N}-STORE now; there is no line/destination choice to make.
def trim_source():
    parts = []
    parts.append(_lead(
        'Scan a LOT into Trim on %s, then scan or tap it back out on %s once '
        'it is ready to move on.' % (_b('Check IN'), _b('Trim OUT'))))

    parts.append(_step(1, 'Check a LOT in',
        'If this press is shared, pick it from %s at the top first. Then '
        'scan the %s - the LOT, item, and eligibility show up for you to '
        'check. Press %s to commit it to this cell.'
        % (_b('Scan or pick a press'), _b('Scan LTT'), _b('Move'))))

    parts.append(_step(2, "It's in Trim now",
        'The LOT shows up under %s for this press. It stays there - no '
        'further action needed - until you check it out.'
        % _b('Currently in Trim')))

    parts.append(_step(3, 'Select the LOT on Trim OUT',
        'Switch to %s. Tap the LOT\'s card in the Trim inventory list, '
        'or scan its %s, then enter the %s.'
        % (_b('Trim OUT'), _b('LTT Barcode'), _b('Lot count'))))

    parts.append(_step(4, 'Add scrap, then check it out',
        'Tap a reason under %s to add one piece; press %s if the reason '
        'you need is not on the short list. Press %s to release the whole '
        'LOT out of Trim.'
        % (_b('Scrap reasons'), _b('More reasons'), _b('Trim OUT'))))
    parts.append(_note(
        'Trim OUT always moves the entire LOT together - there is no split '
        'here.'))

    return ''.join(parts)


# ------------------------------------------------------------ machining -----
# Verified against the live MachiningIn / MachiningOutSplit view.json - not
# the older written guide, which describes a FIFO pick-list-of-LOTs flow that
# no longer exists (both screens are scan/queue-driven now), and not several
# of MachiningOutSplit's OWN on-screen labels, which are stale leftovers from
# before the terminal-mint redesign. The screen's title reads "Machining OUT
# - Sub-LOT Split" and its own SplitNote still talks about a destination and
# a parent that "stays open... until it reaches zero" - none of that is what
# the Submit button actually calls (BlueRidge.Workorder.Machining.mint(), a
# consume-mint that fully consumes what it takes from the queue, no
# destination, no reduced-parent-stays-open loop). This guide follows the
# confirmed script logic, not the on-screen copy.
def machining_in_source():
    parts = []
    parts.append(_lead(
        'Scan the casting you picked up to start machining it at this line.'))

    parts.append(_step(1, 'Scan the LTT',
        'Under %s, scan the %s. The box fills in with the LOT, item, and '
        'piece count so you can check it is the right one before you '
        'confirm.' % (_b('Start Machining'), _b('Scan LTT barcode'))))

    parts.append(_step(2, 'Confirm', 'Press %s. The LOT moves onto %s below, '
        'confirming it is now being worked at this line.'
        % (_b('Start Machining'), _b('Active machined LOT (after pick)'))))

    return ''.join(parts)


def machining_out_source():
    parts = []
    parts.append(_lead(
        'Enter how many pieces to mint out of the castings queued for this '
        'cell, then submit to create one new machined LOT.'))

    parts.append(_step(1, 'Check the queue',
        'Castings pending Machining OUT at this cell are listed oldest '
        'first, and the oldest is already selected as the %s. Tap %s on a '
        'different card only if you need to work a different casting '
        'first.' % (_b('Active Machined LOT'), _b('Select'))))

    parts.append(_step(2, 'Enter Pieces',
        'Under %s, enter how many pieces to mint. This is pulled from the '
        'queue, not just the one selected casting &ndash; if the card you '
        'picked does not have enough by itself, older castings behind it '
        'in the queue cover the rest.' % _b('Extract Sub-LOT')))

    parts.append(_step(3, 'Add scrap if any',
        'Press %s for each defect, pick the reason and enter its count.'
        % _b('+ Add scrap line')))

    parts.append(_step(4, 'Submit',
        'Press %s. It mints one new machined LOT for the pieces you '
        'entered.' % _b('Submit')))
    parts.append(_note(
        'If the queue does not have enough pieces left, you are asked to '
        'confirm minting the smaller amount that is available instead of '
        'being blocked outright.'))

    return ''.join(parts)


# ------------------------------------------------------------- assembly -----
# Verified against the live AssemblyIn / AssemblyNonSerialized /
# AssemblySerialized view.json. Assembly IN is a plain scan queue (matches
# the written guide reasonably well). The other two differ by how a tray
# closes: Non-Serialized reads session.custom.closureMethod (By Count / By
# Weight / By Vision - shown near the header) and only shows a manual
# Complete Tray button for By Count; By Weight/By Vision close on their own
# via the scale/camera, no button. Serialized has NO tray-level button at
# all - its subtitle says "MIP integrated - operator monitoring" and every
# per-piece and per-tray action comes from the PLC handshake. Both screens
# share one manual action beyond that: Complete under the completion gate,
# which finishes and ships the CONTAINER once enough trays have accumulated
# (a single-tray container ships on its own, no button needed).
def assembly_in_source():
    parts = []
    parts.append(_lead(
        'Scan machined components into this cell so Assembly has them '
        'ready to build with.'))

    parts.append(_step(1, 'Scan the LTT',
        'Enter or scan the LTT into %s, then press %s. The component LOT '
        'is added to %s below.'
        % (_b('Scan / enter LTT'), _b('Scan In'), _b('Components at this cell'))))

    return ''.join(parts)


def assembly_nonserialized_source():
    parts = []
    parts.append(_lead(
        'Fill each tray, then complete the container once enough trays '
        'have gone in.'))

    parts.append(_step(1, 'Check what you are building',
        'The %s banner names the part, and %s in the sidebar lists the '
        'component LOTs staged for this cell (scanned in on Assembly IN).'
        % (_b('Now producing'), _b('Components at this cell'))))

    parts.append(_step(2, 'Fill the tray',
        'How a tray closes depends on this line - its closure method '
        '(%s / %s / %s) shows near the header; tap it to open %s if it '
        'needs to change. On %s, enter the count in %s and press %s when '
        'it is full. On %s or %s, the scale or camera closes the tray on '
        'its own at target - there is nothing to press.'
        % (_b('By Count'), _b('By Weight'), _b('By Vision'),
           _b('Change Closure Mode'), _b('By Count'), _b('Parts in tray'),
           _b('Complete Tray'), _b('By Weight'), _b('By Vision'))))

    parts.append(_step(3, 'Complete the container',
        'On a %s line, once enough trays have gone in, press %s under %s '
        'to finish and ship it. A single-tray container ships on its own '
        '- you will not see the gate for it.'
        % (_b('By Count'), _b('Complete'), _b('Container Completion Gate'))))

    return ''.join(parts)


def assembly_serialized_source():
    parts = []
    parts.append(_lead(
        'This line is MIP-integrated - the machine handshakes each piece '
        'and closes each tray on its own. Your job is mostly to watch this '
        'screen and complete the container when it is ready.'))

    parts.append(_step(1, 'Watch the current tray',
        '%s shows what the line has built toward the tray in progress. It '
        'closes on its own, by weight or by count depending on this line - '
        'there is nothing to press for it.' % _b('Current Tray')))

    parts.append(_step(2, 'Complete the container',
        'Once enough trays have gone in, press %s under %s to finish and '
        'ship it. This also posts the shipment to AIM automatically; if '
        'that post fails you get a warning toast, and it retries on its '
        'own - no action needed from you.'
        % (_b('Complete'), _b('WorkOrder Completion Gate'))))

    return ''.join(parts)


# ============================================================ MPP_Config ===
# Config Tool screens - the admin/configuration app, not the shop floor.
# Same dark palette (MPP_Config's Core-derived stylesheet defines the exact
# same --mpp-neutral-* hex values), but the trigger button uses this app's
# own "btn"/"btn-primary" classes, not plant-floor "pf-btn". The popup shell
# (build_config_view below) is otherwise identical to build_view().
#
# The trigger lives in the shared Components/Common/TitleBar component
# (used by AuditLog + FailureLog), extended with optional howToPopupId /
# howToViewPath params - empty by default, so the button only appears once a
# consumer passes them. See that file's own diff for the mechanism.

# ------------------------------------------------------------ audit log -----
# Verified against the live AuditLog view.json.
def audit_log_source():
    parts = []
    parts.append(_lead(
        'Filter the audit trail, then open a row to see exactly what '
        'changed.'))

    parts.append(_step(1, 'Filter',
        'Narrow by %s, %s, a date range, or free-text %s in the sidebar.'
        % (_b('Entity Type'), _b('Severity'), _b('Search'))))

    parts.append(_step(2, 'Run it',
        'Press %s. %s jumps you back to the last 7 days and clears every '
        'filter.' % (_b('Apply'), _b('Reset'))))

    parts.append(_step(3, 'See what changed',
        'Double-click a row to open its full detail, including the old and '
        'new values.'))
    parts.append(_note(
        'If the banner reads &ldquo;Showing first 1000 of N &ndash; narrow '
        'your filter,&rdquo; there are more rows than shown - tighten the '
        'filter to see the rest.'))

    return ''.join(parts)


# ----------------------------------------------------------- failure log ----
# Verified against the live FailureLog view.json. The two "Top ___" tiles are
# not a static summary - clicking a row in either one applies it as a filter
# (sends applyFilterFromTile, which re-runs the search), which is easy to
# miss since nothing about the tile looks clickable.
def failure_log_source():
    parts = []
    parts.append(_lead(
        'Filter what failed, then open a row to see the full detail.'))

    parts.append(_step(1, 'Filter',
        'Narrow by %s, %s, a date range, or free-text %s in the sidebar.'
        % (_b('Entity Type'), _b('Procedure'), _b('Search'))))

    parts.append(_step(2, 'Run it',
        'Press %s. %s jumps you back to the last 7 days and clears every '
        'filter.' % (_b('Apply'), _b('Reset'))))

    parts.append(_step(3, 'See the detail',
        'Click a row to open its full failure detail.'))

    parts.append(_rule())

    parts.append(_callout(INFO_BG, INFO_EDGE,
        'The two tiles up top are shortcuts',
        '%s and %s are not just a summary - click a row in either one and '
        'it filters the log to that reason or procedure for you.'
        % (_b('Top Rejection Reasons (7 days)'), _b('Top Failing Procedures (7 days)'))))

    return ''.join(parts)


# ---------------------------------------------------------- defect codes ----
# Verified against the live DefectCodes + DefectCodeRow view.json.
def defect_codes_source():
    parts = []
    parts.append(_lead(
        'Add, edit, or find a defect code.'))

    parts.append(_step(1, 'Add or edit',
        'Press %s for a new one, or %s on a row to change it &ndash; both '
        'open the same editor.' % (_b('+ Add Code'), _b('Edit'))))

    parts.append(_step(2, 'Find one',
        'Filter by %s, or use %s.' % (_b('Applies to'), _b('Search'))))
    parts.append(_note(
        'A removed code is not gone &ndash; check %s to see it again.'
        % _b('Include deprecated')))

    return ''.join(parts)


# --------------------------------------------------------- downtime codes ---
# Verified against the live DowntimeCodes + DowntimeCodeRow view.json.
def downtime_codes_source():
    parts = []
    parts.append(_lead(
        'Add, edit, or find a downtime code.'))

    parts.append(_step(1, 'Add or edit',
        'Press %s for a new one, or %s on a row to change it &ndash; both '
        'open the same editor.' % (_b('+ Add Code'), _b('Edit'))))

    parts.append(_step(2, 'Find one',
        'Filter by %s or %s, or use %s.'
        % (_b('Applies to'), _b('Reason Type'), _b('Search'))))
    parts.append(_note(
        'A removed code is not gone &ndash; check %s to see it again.'
        % _b('Include deprecated')))

    return ''.join(parts)


# ---------------------------------------------------------------- users -----
# Verified against the live Users + UserRow view.json. Two distinct areas on
# one page: the operator list, and a separate global session-timeout strip.
def users_source():
    parts = []
    parts.append(_lead(
        'Add or edit an operator, and set the session timeouts that apply '
        'everywhere.'))

    parts.append(_step(1, 'Add or edit an operator',
        'Press %s for a new one, or %s on a row to change it &ndash; both '
        'open the same editor.' % (_b('+ Add Operator'), _b('Edit'))))

    parts.append(_step(2, 'Find one',
        'Use %s, or check %s to see removed operators too.'
        % (_b('Search'), _b('Include deprecated'))))

    parts.append(_step(3, 'Session timeouts',
        'Set %s and %s, then press %s. These are global &ndash; every '
        'terminal uses them.'
        % (_b('Operator presence (min)'), _b('Elevation (min)'),
           _b('Save timeouts'))))

    return ''.join(parts)


# --------------------------------------------------------- shift overrides --
# Verified against the live ShiftOverrides + ShiftOverrideRow view.json. The
# page's own subtitle already states the mental model in plain language -
# quoted directly rather than paraphrased.
def shift_overrides_source():
    parts = []
    parts.append(_lead(
        'Extend or shorten a shift on one day for one piece of equipment. '
        'Anything without an override runs the global shift schedule.'))

    parts.append(_step(1, 'Add or edit',
        'Press %s for a new one, or %s on a row to change it &ndash; both '
        'open the same editor.' % (_b('+ Add Override'), _b('Edit'))))

    parts.append(_step(2, 'Find one',
        'Filter by equipment, use %s, or check %s to see ones no longer '
        'active.' % (_b('Search'), _b('Include removed'))))

    return ''.join(parts)


# --------------------------------------------------------- shift schedules --
# Verified against the live ShiftSchedules + ShiftScheduleRow view.json.
# Simplest of the six CRUD-style pages - one shared editor for add and edit,
# no in-page fields of its own.
def shift_schedules_source():
    parts = []
    parts.append(_lead(
        'Add, edit, or find a shift schedule.'))

    parts.append(_step(1, 'Add or edit',
        'Press %s for a new one, or %s on a row to change it &ndash; both '
        'open the same editor, pre-filled when you are editing.'
        % (_b('+ Add Schedule'), _b('Edit'))))

    parts.append(_step(2, 'Find one',
        'Use %s, or check %s to see removed schedules too.'
        % (_b('Search'), _b('Include deprecated'))))

    return ''.join(parts)


# ------------------------------------------------------------ plc devices ---
# Verified against the live PlcDevices view.json. The only page of these six
# with NO popup editor - Add/Edit reveal an inline form on the same page.
# The row action reads "Remove" but its script calls deprecate() - a soft
# flag like everywhere else in this app, not a delete - so the guide says
# "hides" rather than implying the mapping or its history is gone.
def plc_devices_source():
    parts = []
    parts.append(_lead(
        'Map a terminal to the PLC device it reads from.'))

    parts.append(_step(1, 'Pick a terminal',
        'Choose one from %s at the top. Its mappings appear below.'
        % _b('Select a terminal...')))

    parts.append(_step(2, 'Add or edit a mapping',
        'Press %s (enabled once a terminal is picked) or %s on a row. Fill '
        'in %s, %s, %s, and %s, then press %s.'
        % (_b('+ Add mapping'), _b('Edit'), _b('Device Type'),
           _b('Device Code'), _b('UDT Instance Path'), _b('Sort Order'),
           _b('Save'))))
    parts.append(_note('Press %s instead to discard without saving.'
        % _b('Cancel')))

    parts.append(_step(3, 'Remove a mapping',
        'Press %s on a row. This hides the mapping &ndash; it does not '
        'erase it.' % _b('Remove')))

    return ''.join(parts)


# ---------------------------------------------------------- plant hierarchy -
# Verified against the live PlantHierarchy view.json. No Draft/Publish here -
# every change (create, update, deprecate, reorder) takes effect immediately.
def plant_hierarchy_source():
    parts = []
    parts.append(_lead(
        'Add a location to the plant tree, or work with one that already '
        'exists.'))

    parts.append(_step(1, 'Start a new location',
        'Press %s. It opens a blank form.' % _b('+ Add Location')))

    parts.append(_step(2, 'Set its type',
        'Pick %s, then %s &ndash; these decide which attribute fields '
        'show up below.' % (_b('Type'), _b('Definition'))))

    parts.append(_step(3, 'Fill it in and save',
        'Enter %s, %s, %s, and any attributes %s added, then press %s.'
        % (_b('Name'), _b('Code'), _b('Description'), _b('Definition'),
           _b('Save'))))
    parts.append(_note(
        '%s only appears on a Printer location, and checks that the '
        'printer responds before you save.' % _b('Validate endpoint')))

    parts.append(_points('Working with an existing location', [
        ('Edit', 'Select it in the tree, change what you need, then press '
                 '%s. %s discards your changes.'
                 % (_b('Save'), _b('Cancel'))),
        ('Reorder', 'The up/down arrows next to %s move it right away '
                    '&ndash; no %s needed.' % (_b('Sort Order'), _b('Save'))),
        ('Deprecate', 'Press %s. This takes effect immediately, with no '
                      'confirmation step.' % _b('Deprecate')),
    ]))

    return ''.join(parts)


# ------------------------------------------------------------ quality specs
# Verified against the live QualitySpecs view.json. Two levels: the spec
# itself (Name/Description/links, not versioned) and its versions
# (Draft/Published/Deprecated, same lifecycle as BOMs/Routes/Operation
# Templates). Deprecating the SPEC retires every version at once - a
# different, bigger action than deprecating one version.
def quality_specs_source():
    parts = []
    parts.append(_lead(
        'Manage a quality spec and its versioned attribute list.'))

    parts.append(_step(1, 'Add or select a spec',
        'Press %s for a new one, or pick one from the list. %s and %s are '
        'read-only; edit %s or %s and press %s to keep them.'
        % (_b('+ New Spec'), _b('Linked Item'), _b('Linked Operation Template'),
           _b('Name'), _b('Description'), _b('Save Spec'))))

    parts.append(_step(2, 'Work a version',
        '%s opens an editable draft. Add or remove attributes on the %s '
        'tab and set their Target/Lower/Upper values, then %s to keep '
        'working or %s when it is ready.'
        % (_b('+ New Version'), _b('Attributes'), _b('Save Draft'),
           _b('Publish'))))
    parts.append(_note(
        'Publish needs at least one attribute and an %s date.'
        % _b('Effective From')))

    parts.append(_step(3, 'Retire',
        '%s throws away a draft you do not want. %s retires one published '
        'version. %s retires the whole spec and every one of its versions '
        'at once.'
        % (_b('Discard Draft'), _b('Deprecate Version'), _b('Deprecate Spec'))))

    parts.append(_rule())

    parts.append(_callout(INFO_BG, INFO_EDGE,
        'A published or deprecated version is read-only',
        'Press %s to get an editable copy with a new effective date.'
        % _b('+ New Version')))

    return ''.join(parts)


# ------------------------------------------------------- operation templates
# Verified against the live OperationTemplates view.json. Two INDEPENDENT
# save cycles on one screen: the template version itself (Draft/Published/
# Deprecated, via Save + Publish + New Version + Deprecate) and its Data
# Collection Fields grid (its own Save fields/Discard fields, dirty-tracked
# separately - publishing the template does not touch field edits, and
# saving fields does not need a publish).
def operation_templates_source():
    parts = []
    parts.append(_lead(
        'Manage an operation template and the data it collects.'))

    parts.append(_step(1, 'Add or select',
        'Press %s for a new one, or pick one from the list.'
        % _b('+ New Template')))

    parts.append(_step(2, 'Edit and publish',
        'Change %s, %s, or %s and press %s. Press %s once it is ready '
        '&ndash; that only shows while the version is still a draft. %s '
        'makes a new editable version off the current one.'
        % (_b('Name'), _b('Operation Type'), _b('Description'), _b('Save'),
           _b('Publish'), _b('+ New Version'))))

    parts.append(_step(3, 'Data Collection Fields',
        'Press %s to add one, then %s to keep your changes.'
        % (_b('+ Add field'), _b('Save fields'))))
    parts.append(_note(
        'Fields save on their own &ndash; you do not need to Publish for a '
        'field change to take effect.'))

    parts.append(_step(4, 'Deprecate',
        'Press %s to retire the template.' % _b('Deprecate')))

    return ''.join(parts)


# ------------------------------------------------------------------- tools -
# Verified against the live Tools view.json. Cavities/Assignments tabs exist
# alongside Attributes but were not dug into for this guide - mentioned only
# by name, not by behavior, since that was not independently verified.
def tools_source():
    parts = []
    parts.append(_lead(
        'Add, edit, duplicate, or retire a die or tool.'))

    parts.append(_step(1, 'Add or select',
        'Press %s for a new one, or pick one from the list.'
        % _b('+ Add Die')))

    parts.append(_step(2, 'Edit',
        'Change %s, %s, %s, and %s (plus %s on a die), then press %s.'
        % (_b('Name'), _b('Die Rank'), _b('Status'), _b('Description'),
           _b('Shot Limit'), _b('Save'))))

    parts.append(_step(3, 'Duplicate',
        'With a die selected, press %s to copy its configuration into a '
        'new one.' % _b('Duplicate')))

    parts.append(_step(4, 'Retire',
        'Press %s.' % _b('Retire')))
    parts.append(_note(
        '%s manages the list of ranks itself, separate from any one die.'
        % _b('Die Ranks')))

    return ''.join(parts)


# =========================================================== item master ===
# Verified against the live Components/Parts/ItemMaster/{Identity,
# ContainerConfig,Routes,Boms,QualitySpecs,Eligibility}/view.json. Item
# Master is a compound page - each section owns its own header/Save/Discard
# (and, for Routes/Boms, its own Draft/Publish lifecycle), so it gets a
# How-To button PER SECTION rather than one page-level guide, matching how
# each section already manages itself independently.

# ------------------------------------------------------------- identity ----
def item_identity_source():
    parts = []
    parts.append(_lead(
        "Edit a part's core identity and settings."))

    parts.append(_step(1, 'Edit and save',
        'Change any field, then press %s. %s reverts to the last saved '
        'values.' % (_b('Save'), _b('Discard'))))

    parts.append(_step(2, 'Deprecate',
        'Press %s. This also deprecates the part\'s routes, BOMs, '
        'eligibility, and container config together, and is blocked while '
        'any LOT of the part is still active.' % _b('Deprecate')))

    parts.append(_rule())

    parts.append(_callout(INFO_BG, INFO_EDGE,
        'Two fields worth knowing',
        '%s is the standard pieces per basket &ndash; one LOT, one LTT '
        'label, at Die Cast, Trim, and intermediate Machining. %s sets the '
        'default split size used at Machining OUT.'
        % (_b('Parts Per Basket'), _b('Default Sub-Lot Qty'))))

    return ''.join(parts)


# -------------------------------------------------------- container config -
def item_container_config_source():
    parts = []
    parts.append(_lead(
        'Configure how this part packs out &ndash; by count, by weight, '
        'or by vision. A part can have more than one method configured.'))

    parts.append(_step(1, 'Add or clear a method',
        'Press %s for whichever methods apply, or %s to remove one.'
        % (_b('Add By Count/Weight/Vision pack-out'), _b('Clear'))))

    parts.append(_step(2, 'Fill in the numbers',
        '%s, %s, %s, and %s. %s also needs a %s above zero.'
        % (_b('Parts Per Tray'), _b('Trays Per Container'), _b('Dunnage Code'),
           _b('Serialized'), _b('By Weight'), _b('Target Weight'))))

    parts.append(_step(3, 'Save', 'Press %s.' % _b('Save')))
    parts.append(_note(
        '%s greater than zero requires %s too, or Save will reject it.'
        % (_b('Parts Per Tray'), _b('Trays Per Container'))))

    return ''.join(parts)


# ------------------------------------------------------------------ routes -
def item_routes_source():
    parts = []
    parts.append(_lead(
        "Build and publish this part's route &ndash; the sequence of "
        'production steps it follows.'))

    parts.append(_step(1, 'Pick a version',
        'The dropdown lists every version, with a badge for its status '
        '(Draft, Published, or Deprecated).'))

    parts.append(_step(2, 'Edit the draft',
        'Set %s and %s, then press %s for each production step. %s keeps '
        'your progress; %s throws the draft away.'
        % (_b('Name'), _b('Effective From'), _b('+ Add Step'),
           _b('Save Draft'), _b('Discard Draft'))))

    parts.append(_step(3, 'Publish',
        'Needs at least one step, and every step needs an Operation '
        'Template. If another version is currently published, publishing '
        'this one deprecates it &ndash; you will be asked to confirm.'))

    parts.append(_step(4, 'Retire or branch',
        '%s retires a published version. %s makes a new editable draft '
        'off whichever version you are viewing.'
        % (_b('Deprecate'), _b('+ New Version'))))

    parts.append(_rule())

    parts.append(_callout(INFO_BG, INFO_EDGE,
        'A published or deprecated version is read-only',
        'Press %s to get an editable copy.' % _b('+ New Version')))

    return ''.join(parts)


# -------------------------------------------------------------------- boms -
def item_boms_source():
    parts = []
    parts.append(_lead(
        "Build and publish this part's BOM &ndash; the components it "
        'consumes.'))

    parts.append(_step(1, 'Pick a version',
        'The dropdown lists every version, with a badge for its status '
        '(Draft, Published, or Deprecated).'))

    parts.append(_step(2, 'Edit the draft',
        'Set %s, then press %s for each component. %s keeps your '
        'progress; %s throws the draft away.'
        % (_b('Effective From'), _b('+ Add Component'), _b('Save Draft'),
           _b('Discard Draft'))))

    parts.append(_step(3, 'Publish',
        'Needs at least one component line and an %s date. If another '
        'version is currently published, publishing this one deprecates '
        'it &ndash; you will be asked to confirm.' % _b('Effective From')))

    parts.append(_step(4, 'Retire or branch',
        '%s retires a published version. %s makes a new editable draft '
        'off whichever version you are viewing.'
        % (_b('Deprecate'), _b('+ New Version'))))

    parts.append(_rule())

    parts.append(_callout(INFO_BG, INFO_EDGE,
        'A published or deprecated version is read-only',
        'Press %s to get an editable copy.' % _b('+ New Version')))

    return ''.join(parts)


# ---------------------------------------------------- quality specs (link) -
# This tab is a read-only linker, not an editor - confirmed no Save/Publish
# controls exist here at all.
def item_quality_specs_source():
    parts = []
    parts.append(_lead(
        'See which quality specs are linked to this part.'))

    parts.append(_step(1, 'Open one',
        'Select a spec in the table, then press %s to open and edit it on '
        'the Quality Specs page.' % _b('Go to spec →')))

    return ''.join(parts)


# ------------------------------------------------------------ eligibility --
def item_eligibility_source():
    parts = []
    parts.append(_lead(
        'Decide which locations this part is eligible at, and how it '
        'behaves when consumed there.'))

    parts.append(_step(1, 'Add a location',
        'Press %s and pick the %s. Eligibility cascades down to every '
        'Cell beneath the tier you choose.'
        % (_b('+ Add Location'), _b('Location'))))

    parts.append(_step(2, 'Turn on Consumption if it applies',
        '%s means this location consumes the part as an input, which '
        'unlocks %s, %s, and %s for scan-in.'
        % (_b('Consumption'), _b('Min'), _b('Max'), _b('Default'))))

    parts.append(_step(3, 'Save', 'Press %s.' % _b('Save')))

    return ''.join(parts)


# --------------------------------------------------------------- die tabs --
# Verified against the live Components/Parts/Tools/{Attributes,Cavities,
# Assignments}/view.json - the three tabs shown for a selected die on the
# Tools page. "+ New definition" and "+ Add" on Attributes look similar but
# do different things: New definition creates a brand-new attribute type
# available to every tool of this TYPE; Add just adds a row for an existing
# definition to THIS die.
def die_tabs_source():
    parts = []
    parts.append(_lead(
        "Manage a die's attributes, cavities, and cell assignment."))

    parts.append(_step(1, 'Attributes',
        'Press %s to add a value for an attribute that already exists on '
        'this tool type, then %s.'
        % (_b('+ Add'), _b('Save'))))
    parts.append(_note(
        '%s creates a brand-new attribute type for every die of this kind '
        '&ndash; only use it when the attribute does not exist yet.'
        % _b('+ New definition')))

    parts.append(_step(2, 'Cavities',
        'Press %s for each cavity, fill in its %s, %s, and %s, then %s.'
        % (_b('+ Add cavity'), _b('Number'), _b('Description'), _b('Status'),
           _b('Save'))))

    parts.append(_step(3, 'Assignments',
        'The top shows where this die is mounted now. Pick a %s and press '
        '%s to assign it there; press %s to take it off. The table below '
        'keeps a full history of every past assignment.'
        % (_b('Cell'), _b('Mount'), _b('Release'))))

    return ''.join(parts)


# ==================================================== MPP editor popups ====
# Reusable workflow popups opened from plant-floor screens. Verified against
# the live view.json for each - button scripts, not labels, since one of
# these (ChangeoverElevation) has a real silent-no-op trap and another
# (MoveOverride) has a button whose label overstates what its own script
# does (it only authenticates; the calling screen performs the move).

# ---------------------------------------------------------- downtime -------
# Verified against DowntimeManager + DowntimeEditor + EventRow view.json.
# End needs no supervisor sign-in; changing the Reason, Edit, and Void all
# do (a hidden AD-elevation gate the operator only discovers on click).
def downtime_manager_source():
    parts = []
    parts.append(_lead(
        'Start, edit, or end downtime for this cell.'))

    parts.append(_step(1, 'Start it',
        'Press %s. It opens with no reason yet &ndash; pick one on the row '
        'once you know it.' % _b('Start Downtime')))

    parts.append(_step(2, 'End it',
        'Press %s on the row when work resumes. No supervisor sign-in '
        'needed.' % _b('End')))

    parts.append(_step(3, 'Add a past event',
        'Press %s. Fill in %s and %s, or check %s if you only know how '
        'long it ran, not the exact times.'
        % (_b('Add Past Event'), _b('Start (ET)'), _b('End (ET)'),
           _b('Duration only'))))
    parts.append(_note(
        'A past event needs both a start and an end &ndash; leaving %s '
        'blank is only allowed when editing a downtime that is still '
        'open.' % _b('End (ET)')))

    parts.append(_step(4, 'Edit or Void',
        '%s and %s both ask for a supervisor sign-in first. %s is '
        'permanent.' % (_b('Edit'), _b('Void'), _b('Void'))))

    return ''.join(parts)


# ------------------------------------------------------------ scrap entry --
# Verified against ScrapEntry view.json. Quantity is a plain text field, not
# a numeric one - the Record Scrap button stays disabled until LOT, Defect
# Code, and a positive Quantity are all set.
def scrap_entry_source():
    parts = []
    parts.append(_lead(
        'Record scrap against a LOT at this cell.'))

    parts.append(_step(1, 'Fill it in',
        'Pick the %s, the %s, and enter the %s.'
        % (_b('LOT'), _b('Defect Code'), _b('Quantity'))))

    parts.append(_step(2, 'Submit',
        'Add a %s if it helps, then press %s.'
        % (_b('Remarks'), _b('Record Scrap'))))

    return ''.join(parts)


# --------------------------------------------------------- move override ---
# Verified against MoveOverride view.json. "Authorize & move" only
# authenticates - the move itself runs back on the scan screen that opened
# this popup, once it hears the authorization succeeded.
def move_override_source():
    parts = []
    parts.append(_lead(
        "Get a supervisor's sign-off on a move that's normally blocked "
        '(for example, moving a LOT backward on its route).'))

    parts.append(_step(1, 'Authorize',
        'Enter the supervisor\'s %s and %s, then press %s.'
        % (_b('Supervisor AD account'), _b('Password'), _b('Authorize & move'))))
    parts.append(_note(
        'This only signs off the request &ndash; the move itself completes '
        'automatically back on the scan screen once authorization goes '
        'through.'))

    return ''.join(parts)


# ------------------------------------------------ change closure mode ------
# Verified against ChangeoverElevation view.json. Confirm changeover only
# acts on whichever field actually changed - leaving both the mode and the
# CRT toggle untouched closes the popup with no call made and no toast, a
# silent no-op that looks identical to success.
def changeover_elevation_source():
    parts = []
    parts.append(_lead(
        "Change this line's closure method, its CRT hold setting, or "
        'both.'))

    parts.append(_step(1, 'Choose what to change',
        'Pick a %s if you are changing it, and/or toggle %s if you are '
        'changing that.'
        % (_b('New closure mode'),
           _b('Hold containers for second-person validation'))))

    parts.append(_step(2, 'Authorize',
        "Enter the supervisor's %s and %s, then press %s."
        % (_b('AD account'), _b('Password'), _b('Confirm changeover'))))
    parts.append(_note(
        'Only whatever you actually changed gets applied. Leaving both '
        'the mode and the CRT toggle alone and pressing %s does nothing '
        '&ndash; there is no error, it just closes.' % _b('Confirm changeover')))

    return ''.join(parts)


# ------------------------------------------------------- CRT validation ----
# Verified against CrtValidation + CrtContainerRow view.json. One sign-in
# covers the whole list, not one per row.
def crt_validation_source():
    parts = []
    parts.append(_lead(
        'Validate or hold CRT containers waiting for review.'))

    parts.append(_step(1, 'Sign in once',
        "Enter a supervisor's account and password and press %s. That "
        'one sign-in covers every container in the list.' % _b('Unlock')))

    parts.append(_step(2, 'Work the list',
        'Press %s to clear a container, or %s to set it aside for '
        'further review.' % (_b('Validate'), _b('Hold'))))
    parts.append(_note(
        '%s does not ask for a reason &ndash; it is always logged as held '
        'for supervisor review.' % _b('Hold')))

    return ''.join(parts)


# ------------------------------------------------- AIM connection settings -
# Verified against AimConnectionSettings view.json. Every field loads with
# its CURRENT value already filled in - the "leave blank to keep current"
# placeholder only shows if you deliberately clear a field.
def aim_connection_settings_source():
    parts = []
    parts.append(_lead(
        "Update this line's AIM connection settings."))

    parts.append(_step(1, 'Change only what needs to change',
        'Every field opens filled in with its current value. Edit the '
        'ones you need to change and leave the rest alone.'))
    parts.append(_note(
        'Clearing a field on purpose keeps its stored value rather than '
        'blanking it out &ndash; it is built for partial updates, not a '
        'reset.'))

    parts.append(_step(2, 'Save', 'Press %s.' % _b('Save')))

    parts.append(_rule())

    parts.append(_callout(WARN_BG, WARN_EDGE,
        'Never point this at 99',
        '%s is test. 99 is live production &ndash; do not enter it here.'
        % _b('01')))

    return ''.join(parts)


# -------------------------------------------------------- register operator
# Verified against RegisterOperator view.json.
def register_operator_source():
    parts = []
    parts.append(_lead(
        'Create a new operator record.'))

    parts.append(_step(1, 'Confirm the details',
        'Check the %s and type the %s.'
        % (_b('Initials'), _b('Display Name'))))

    parts.append(_step(2, 'Save',
        'Press %s.' % _b('Save & Continue')))

    return ''.join(parts)


# ----------------------------------------------------------- paused lots ---
# Verified against PausedLotList + PausedLotRow view.json.
def paused_lot_list_source():
    parts = []
    parts.append(_lead(
        'See and resume LOTs paused at this cell.'))

    parts.append(_step(1, 'Resume one',
        'Press %s on a LOT to bring it back. It resumes right away '
        '&ndash; there is no confirmation step.' % _b('Resume')))

    return ''.join(parts)


# ============================================ MPP_Config editor popups ====
# Reusable Add/Edit popups opened from the Config Tool's list pages.
# Verified against each popup's own script bodies, not its labels.

# ------------------------------------------------------- defect code editor
def defect_code_editor_source():
    parts = []
    parts.append(_lead(
        'Add or edit a defect code.'))

    parts.append(_step(1, 'Fill it in',
        'Pick %s first &ndash; on a new code, it fills in a starting %s '
        'for you. %s is optional (a blank field applies plant-wide).'
        % (_b('Applies to'), _b('Code'), _b('Applies to'))))
    parts.append(_note(
        '%s cannot change once the code is created.' % _b('Code')))

    parts.append(_step(2, 'Save', 'Press %s.' % _b('Save')))

    parts.append(_step(3, 'Deprecate',
        'Press %s to retire the code.' % _b('Deprecate')))

    return ''.join(parts)


# ----------------------------------------------------- downtime code editor
def downtime_code_editor_source():
    parts = []
    parts.append(_lead(
        'Add or edit a downtime code.'))

    parts.append(_step(1, 'Fill it in',
        'Pick %s if it applies to one area, and %s if this reason has a '
        'type. Both are optional.' % (_b('Applies to'), _b('Reason Type'))))
    parts.append(_note(
        '%s cannot change once the code is created.' % _b('Code')))

    parts.append(_step(2, 'Save', 'Press %s.' % _b('Save')))

    parts.append(_step(3, 'Deprecate',
        'Press %s to retire the code.' % _b('Deprecate')))

    return ''.join(parts)


# -------------------------------------------------------------- operators --
def operator_editor_source():
    parts = []
    parts.append(_lead(
        'Add or edit an operator.'))

    parts.append(_step(1, 'Fill it in',
        'Enter %s and %s. %s is optional &ndash; add it only if this '
        'operator signs in with an AD account.'
        % (_b('Initials'), _b('Display Name'), _b('AD Account'))))

    parts.append(_step(2, 'Save', 'Press %s.' % _b('Save')))

    parts.append(_step(3, 'Deprecate',
        'Press %s to retire the operator.' % _b('Deprecate')))

    return ''.join(parts)


# --------------------------------------------------------- shift overrides -
def shift_override_editor_source():
    parts = []
    parts.append(_lead(
        'Add or edit a one-day exception to a shift schedule.'))

    parts.append(_step(1, 'Pick what it is for',
        'Choose the %s, %s, and %s &ndash; once saved, these three cannot '
        'change. Moving an override means removing it and adding a new '
        'one.' % (_b('Equipment'), _b('Shift'), _b('Date'))))

    parts.append(_step(2, 'Set the times',
        'Enter %s and %s as 24-hour %s &ndash; picking the shift fills '
        'these in first, so only change them if this day is actually '
        'different.' % (_b('Start'), _b('End'), _b('HH:MM'))))
    parts.append(_note(
        'An overnight shift is fine &ndash; End earlier than Start just '
        'means it crosses midnight. Start and End only need to differ '
        'from each other.'))

    parts.append(_step(3, 'Save', 'Press %s.' % _b('Save')))

    parts.append(_step(4, 'Remove',
        'Press %s. The record is kept so past OEE figures can still be '
        'explained &ndash; it is hidden, not erased.' % _b('Remove')))

    return ''.join(parts)


# --------------------------------------------------------- shift schedules -
def shift_schedule_editor_source():
    parts = []
    parts.append(_lead(
        'Add or edit a shift schedule.'))

    parts.append(_step(1, 'Fill it in',
        'Enter a %s, tap every day it runs under %s, and set %s and %s '
        'as 24-hour %s.'
        % (_b('Name'), _b('Days of Week'), _b('Start Time'), _b('End Time'),
           _b('HH:MM'))))
    parts.append(_note(
        'A %s date is required, and at least one day must be checked, or '
        'Save will reject it.' % _b('Effective From')))

    parts.append(_step(2, 'Save', 'Press %s.' % _b('Save')))

    parts.append(_step(3, 'Deprecate',
        'Press %s to retire the schedule.' % _b('Deprecate')))

    return ''.join(parts)


# ------------------------------------------------------------- add item ----
def add_item_source():
    parts = []
    parts.append(_lead(
        'Create a new part.'))

    parts.append(_step(1, 'Fill in the identity',
        '%s, %s, and %s are required.'
        % (_b('Part Number'), _b('Item Type'), _b('UOM'))))

    parts.append(_step(2, 'Add what you know',
        'Weight, Country of Origin, Default Sub-Lot Qty, Parts Per '
        'Basket, Max Parts, and the Macola cross-reference are all '
        'optional &ndash; fill in what applies now and come back for the '
        'rest later on the item\'s own Identity tab.'))

    parts.append(_step(3, 'Create',
        'Press %s.' % _b('Create Item')))

    return ''.join(parts)


# -------------------------------------------------------------- add die ----
def add_die_source():
    parts = []
    parts.append(_lead(
        'Create a new die.'))

    parts.append(_step(1, 'Fill it in',
        '%s and %s are required. %s defaults to B if you leave it alone.'
        % (_b('Code'), _b('Name'), _b('Die Rank'))))

    parts.append(_step(2, 'Create',
        'Press %s.' % _b('Create Die')))
    parts.append(_note(
        'A new die always starts Active with tool type Die &ndash; there '
        'is nothing to set for either one here.'))

    return ''.join(parts)


# --------------------------------------------------------- duplicate die ---
def duplicate_die_source():
    parts = []
    parts.append(_lead(
        "Copy a die's configuration into a new one."))

    parts.append(_step(1, 'Select a source die first',
        'Pick the die to copy on the Tools screen, then press %s '
        'there.' % _b('Duplicate')))

    parts.append(_step(2, 'Name the copy',
        'Enter a %s and %s for the new die.' % (_b('New Code'), _b('New Name'))))
    parts.append(_note(
        'Die Rank, Shot Limit, cavities, attributes, and description all '
        'carry over from the source die &ndash; cavities copy exactly, '
        'including any that are Closed or Scrapped.'))

    parts.append(_step(3, 'Create',
        'Press %s.' % _b('Duplicate Die')))
    parts.append(_note(
        'The new die starts clean otherwise: shot count resets to 0, '
        'status is Active, and cell mount history is not copied.'))

    return ''.join(parts)


# -------------------------------------------------------------- edit rank --
def edit_rank_source():
    parts = []
    parts.append(_lead(
        'Add or edit a die rank.'))

    parts.append(_step(1, 'Fill it in',
        'Enter %s and %s.' % (_b('Code'), _b('Name'))))

    parts.append(_step(2, 'Save',
        'Press %s &ndash; it saves either way, whether you are adding a '
        'rank or editing one.' % _b('Create Rank')))

    parts.append(_step(3, 'Remove',
        'Press %s. This cannot be undone from here.' % _b('Remove')))

    return ''.join(parts)


# -------------------------------------------------------------- die ranks --
def die_ranks_source():
    parts = []
    parts.append(_lead(
        'Manage the list of die ranks and which ranks can share a line.'))

    parts.append(_step(1, 'Add or edit a rank',
        'Press %s for a new one, or %s on a row to change it.'
        % (_b('+ Add Rank'), _b('Edit'))))

    parts.append(_step(2, 'Set which ranks can merge',
        'Tap a cell in the grid to flip it between %s and %s for that '
        'pair of ranks.' % (_b('Can merge'), _b('Blocked'))))
    parts.append(_note(
        'Tapping a cell only changes it on screen &ndash; nothing is '
        'saved until you press Save.'))

    parts.append(_step(3, 'Save', 'Press %s.' % _b('Save')))

    return ''.join(parts)


# ------------------------------------------------- location type editor ----
def location_type_editor_source():
    parts = []
    parts.append(_lead(
        'Define the attribute schema for a location type, tier by tier.'))

    parts.append(_step(1, 'Pick a tier, then a definition',
        'Choose a %s, then tap a definition chip to open it, or press %s '
        'for a new one under that tier.'
        % (_b('Location Type (ISA-95 Tier)'), _b('+ Add'))))
    parts.append(_note(
        'Switching tiers drops whatever you were editing with no warning '
        '&ndash; save first if you want to keep it.'))

    parts.append(_step(2, 'Edit the definition',
        'Set %s, %s, and an optional %s and %s. %s locks once the '
        'definition is saved for the first time.'
        % (_b('Code'), _b('Name'), _b('Icon'), _b('Description'), _b('Code'))))

    parts.append(_step(3, 'Edit its attributes',
        'Press %s for each attribute this location type needs, and set '
        'its %s, %s, and whether it is %s. The arrows reorder the list; '
        '%s takes one out.'
        % (_b('+ Add Attribute'), _b('Attribute Name'), _b('Data Type'),
           _b('Required'), _b('Remove'))))

    parts.append(_step(4, 'Save', 'Press %s.' % _b('Save')))

    parts.append(_rule())

    parts.append(_callout(WARN_BG, WARN_EDGE,
        'Deprecate has no confirmation step',
        'Pressing %s retires the definition and every one of its '
        'attributes immediately &ndash; there is no "are you sure?" '
        'prompt. It only succeeds if no Location still uses this '
        'definition.' % _b('Deprecate')))

    return ''.join(parts)


# --------------------------------------------------- new operation template
def new_operation_template_source():
    parts = []
    parts.append(_lead(
        'Create a new operation template.'))

    parts.append(_step(1, 'Fill it in',
        'Enter %s and %s, then pick a %s &ndash; picking one may fill in '
        '%s for you if it is the only one available.'
        % (_b('Code'), _b('Name'), _b('Category'), _b('Operation'))))
    parts.append(_note(
        'Changing %s clears whatever you had picked for %s, so pick '
        'Category first.' % (_b('Category'), _b('Operation'))))

    parts.append(_step(2, 'Create',
        'Press %s.' % _b('Create Template')))

    return ''.join(parts)


# --------------------------------------------------------- new spec modal --
def new_spec_modal_source():
    parts = []
    parts.append(_lead(
        'Create a new quality spec.'))

    parts.append(_step(1, 'Fill it in',
        '%s is the only required field. %s, %s, and %s are all optional '
        'and can be filled in later.'
        % (_b('Name'), _b('Linked Item'), _b('Description'),
           _b('Initial Effective Date'))))
    parts.append(_note(
        'There is no field here for an Operation Template link &ndash; '
        'set that afterward on the spec itself.'))

    parts.append(_step(2, 'Create',
        'Press %s.' % _b('Create')))

    return ''.join(parts)


# ---------------------------------------------- add attribute definition ---
def add_attribute_definition_source():
    parts = []
    parts.append(_lead(
        'Define a brand-new attribute type for every die of this tool '
        'type.'))

    parts.append(_step(1, 'Fill it in',
        'Enter %s and %s, pick its %s, and check %s if every die of this '
        'type must have a value for it.'
        % (_b('Code'), _b('Name'), _b('Data Type'), _b('Required'))))

    parts.append(_step(2, 'Create',
        'Press %s.' % _b('Create Definition')))

    return ''.join(parts)


def build_config_view(source_html, default_size, title, popup_id):
    """Same shell as build_view() (Header + Body, self-drawn - see that
    function's docstring for why no title=/draggable= on openPopup), styled
    with MPP_Config's own "btn"/"btn-primary" classes instead of plant-floor
    "pf-btn"."""
    return {
        "custom": {},
        "params": {"popupId": popup_id},
        "propConfig": {
            "params.popupId": {"paramDirection": "input"},
        },
        "props": {"defaultSize": default_size},
        "root": {
            "type": "ia.container.flex",
            "meta": {"name": "root"},
            "props": {
                "direction": "column",
                "style": {"classes": "modal"},
            },
            "children": [
                {
                    "type": "ia.container.flex",
                    "meta": {"name": "Header"},
                    "position": {"shrink": 0},
                    "props": {"style": {"classes": "modal-header"}},
                    "children": [
                        {
                            "type": "ia.display.label",
                            "meta": {"name": "Title"},
                            "position": {"grow": 1},
                            "props": {"text": title},
                        },
                        {
                            "type": "ia.display.icon",
                            "meta": {"name": "CloseIcon"},
                            "props": {
                                "path": "mpp/cancel",
                                "style": {
                                    "classes": "modal-close",
                                    "cursor": "pointer",
                                    "height": "18px",
                                    "width": "18px",
                                },
                            },
                            "events": {
                                "dom": {
                                    "onClick": {
                                        "scope": "G",
                                        "type": "script",
                                        "config": {
                                            "script": (
                                                "\tsystem.perspective."
                                                "closePopup(id=self.view."
                                                "params.popupId)"
                                            )
                                        },
                                    }
                                }
                            },
                        },
                    ],
                },
                {
                    "type": "ia.container.flex",
                    "meta": {"name": "Body"},
                    "position": {"basis": "0px", "grow": 1},
                    "props": {"direction": "column", "style": {"classes": "modal-body"}},
                    "children": [
                        {
                            "type": "ia.display.markdown",
                            "meta": {"name": "Guide"},
                            "position": {"basis": "0px", "grow": 1},
                            "props": {
                                "source": source_html,
                                "markdown": {"escapeHtml": False},
                                "sectionSpacing": 8,
                                "style": {"fontSize": 13, "overflow": "auto"},
                            },
                        }
                    ],
                },
            ],
        },
    }


GUIDES = [
    {
        "dir": os.path.join(MPP_VIEWS, "Components", "Popups", "DieCastHowTo"),
        "source": diecast_source,
        "defaultSize": {"width": 720, "height": 620},
        "title": "How to run Die Cast",
        "popupId": "dieCastHowTo",
    },
    {
        "dir": os.path.join(MPP_VIEWS, "Components", "Popups", "TrimHowTo"),
        "source": trim_source,
        "defaultSize": {"width": 720, "height": 520},
        "title": "How to run Trim",
        "popupId": "trimHowTo",
    },
    {
        "dir": os.path.join(MPP_VIEWS, "Components", "Popups", "MachiningInHowTo"),
        "source": machining_in_source,
        "defaultSize": {"width": 680, "height": 400},
        "title": "How to run Machining IN",
        "popupId": "machiningInHowTo",
    },
    {
        "dir": os.path.join(MPP_VIEWS, "Components", "Popups", "MachiningOutHowTo"),
        "source": machining_out_source,
        "defaultSize": {"width": 720, "height": 560},
        "title": "How to run Machining OUT",
        "popupId": "machiningOutHowTo",
    },
    {
        "dir": os.path.join(MPP_VIEWS, "Components", "Popups", "AssemblyInHowTo"),
        "source": assembly_in_source,
        "defaultSize": {"width": 640, "height": 340},
        "title": "How to run Assembly IN",
        "popupId": "assemblyInHowTo",
    },
    {
        "dir": os.path.join(MPP_VIEWS, "Components", "Popups", "AssemblyNonSerializedHowTo"),
        "source": assembly_nonserialized_source,
        "defaultSize": {"width": 720, "height": 560},
        "title": "How to run Assembly (Non-Serialized)",
        "popupId": "assemblyNonSerializedHowTo",
    },
    {
        "dir": os.path.join(MPP_VIEWS, "Components", "Popups", "AssemblySerializedHowTo"),
        "source": assembly_serialized_source,
        "defaultSize": {"width": 680, "height": 440},
        "title": "How to run Assembly (Serialized)",
        "popupId": "assemblySerializedHowTo",
    },
    {
        "dir": os.path.join(MPP_VIEWS, "Components", "Popups", "DowntimeManagerHowTo"),
        "source": downtime_manager_source,
        "defaultSize": {"width": 640, "height": 440},
        "title": "How to manage downtime",
        "popupId": "downtimeManagerHowTo",
    },
    {
        "dir": os.path.join(MPP_VIEWS, "Components", "Popups", "ScrapEntryHowTo"),
        "source": scrap_entry_source,
        "defaultSize": {"width": 560, "height": 340},
        "title": "How to record scrap",
        "popupId": "scrapEntryHowTo",
    },
    {
        "dir": os.path.join(MPP_VIEWS, "Components", "Popups", "MoveOverrideHowTo"),
        "source": move_override_source,
        "defaultSize": {"width": 560, "height": 320},
        "title": "How to authorize a move override",
        "popupId": "moveOverrideHowTo",
    },
    {
        "dir": os.path.join(MPP_VIEWS, "Components", "Popups", "ChangeoverElevationHowTo"),
        "source": changeover_elevation_source,
        "defaultSize": {"width": 580, "height": 360},
        "title": "How to change closure mode",
        "popupId": "changeoverElevationHowTo",
    },
    {
        "dir": os.path.join(MPP_VIEWS, "Components", "Popups", "CrtValidationHowTo"),
        "source": crt_validation_source,
        "defaultSize": {"width": 580, "height": 340},
        "title": "How to validate CRT containers",
        "popupId": "crtValidationHowTo",
    },
    {
        "dir": os.path.join(MPP_VIEWS, "Components", "Popups", "AimConnectionSettingsHowTo"),
        "source": aim_connection_settings_source,
        "defaultSize": {"width": 600, "height": 400},
        "title": "How to update AIM connection settings",
        "popupId": "aimConnectionSettingsHowTo",
    },
    {
        "dir": os.path.join(MPP_VIEWS, "Components", "Popups", "RegisterOperatorHowTo"),
        "source": register_operator_source,
        "defaultSize": {"width": 520, "height": 300},
        "title": "How to register a new operator",
        "popupId": "registerOperatorHowTo",
    },
    {
        "dir": os.path.join(MPP_VIEWS, "Components", "Popups", "PausedLotListHowTo"),
        "source": paused_lot_list_source,
        "defaultSize": {"width": 480, "height": 260},
        "title": "How to resume a paused LOT",
        "popupId": "pausedLotListHowTo",
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "AuditLogHowTo"),
        "source": audit_log_source,
        "defaultSize": {"width": 680, "height": 440},
        "title": "How to use the Audit Log",
        "popupId": "auditLogHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "FailureLogHowTo"),
        "source": failure_log_source,
        "defaultSize": {"width": 680, "height": 460},
        "title": "How to use the Failure Log",
        "popupId": "failureLogHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "DefectCodesHowTo"),
        "source": defect_codes_source,
        "defaultSize": {"width": 600, "height": 360},
        "title": "How to manage Defect Codes",
        "popupId": "defectCodesHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "DowntimeCodesHowTo"),
        "source": downtime_codes_source,
        "defaultSize": {"width": 600, "height": 380},
        "title": "How to manage Downtime Codes",
        "popupId": "downtimeCodesHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "UsersHowTo"),
        "source": users_source,
        "defaultSize": {"width": 620, "height": 420},
        "title": "How to manage Users",
        "popupId": "usersHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "ShiftOverridesHowTo"),
        "source": shift_overrides_source,
        "defaultSize": {"width": 640, "height": 400},
        "title": "How to manage Shift Overrides",
        "popupId": "shiftOverridesHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "ShiftSchedulesHowTo"),
        "source": shift_schedules_source,
        "defaultSize": {"width": 600, "height": 360},
        "title": "How to manage Shift Schedules",
        "popupId": "shiftSchedulesHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "PlcDevicesHowTo"),
        "source": plc_devices_source,
        "defaultSize": {"width": 640, "height": 420},
        "title": "How to map PLC Devices",
        "popupId": "plcDevicesHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "PlantHierarchyHowTo"),
        "source": plant_hierarchy_source,
        "defaultSize": {"width": 680, "height": 440},
        "title": "How to manage the Plant Hierarchy",
        "popupId": "plantHierarchyHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "QualitySpecsHowTo"),
        "source": quality_specs_source,
        "defaultSize": {"width": 680, "height": 500},
        "title": "How to manage Quality Specs",
        "popupId": "qualitySpecsHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "OperationTemplatesHowTo"),
        "source": operation_templates_source,
        "defaultSize": {"width": 680, "height": 460},
        "title": "How to manage Operation Templates",
        "popupId": "operationTemplatesHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "ToolsHowTo"),
        "source": tools_source,
        "defaultSize": {"width": 660, "height": 460},
        "title": "How to manage Tools",
        "popupId": "toolsHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "ItemIdentityHowTo"),
        "source": item_identity_source,
        "defaultSize": {"width": 660, "height": 440},
        "title": "How to edit Item Identity",
        "popupId": "itemIdentityHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "ItemContainerConfigHowTo"),
        "source": item_container_config_source,
        "defaultSize": {"width": 640, "height": 420},
        "title": "How to configure Container Config",
        "popupId": "itemContainerConfigHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "ItemRoutesHowTo"),
        "source": item_routes_source,
        "defaultSize": {"width": 680, "height": 480},
        "title": "How to manage Routes",
        "popupId": "itemRoutesHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "ItemBomsHowTo"),
        "source": item_boms_source,
        "defaultSize": {"width": 680, "height": 480},
        "title": "How to manage BOMs",
        "popupId": "itemBomsHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "ItemQualitySpecsHowTo"),
        "source": item_quality_specs_source,
        "defaultSize": {"width": 560, "height": 280},
        "title": "How to use linked Quality Specs",
        "popupId": "itemQualitySpecsHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "ItemEligibilityHowTo"),
        "source": item_eligibility_source,
        "defaultSize": {"width": 620, "height": 400},
        "title": "How to manage Eligibility",
        "popupId": "itemEligibilityHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "DieTabsHowTo"),
        "source": die_tabs_source,
        "defaultSize": {"width": 640, "height": 420},
        "title": "How to use the die tabs",
        "popupId": "dieTabsHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "DefectCodeEditorHowTo"),
        "source": defect_code_editor_source,
        "defaultSize": {"width": 560, "height": 340},
        "title": "How to edit a Defect Code",
        "popupId": "defectCodeEditorHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "DowntimeCodeEditorHowTo"),
        "source": downtime_code_editor_source,
        "defaultSize": {"width": 560, "height": 340},
        "title": "How to edit a Downtime Code",
        "popupId": "downtimeCodeEditorHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "OperatorEditorHowTo"),
        "source": operator_editor_source,
        "defaultSize": {"width": 540, "height": 320},
        "title": "How to edit an Operator",
        "popupId": "operatorEditorHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "ShiftOverrideEditorHowTo"),
        "source": shift_override_editor_source,
        "defaultSize": {"width": 600, "height": 440},
        "title": "How to edit a Shift Override",
        "popupId": "shiftOverrideEditorHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "ShiftScheduleEditorHowTo"),
        "source": shift_schedule_editor_source,
        "defaultSize": {"width": 580, "height": 380},
        "title": "How to edit a Shift Schedule",
        "popupId": "shiftScheduleEditorHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "AddItemHowTo"),
        "source": add_item_source,
        "defaultSize": {"width": 560, "height": 360},
        "title": "How to add an Item",
        "popupId": "addItemHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "AddDieHowTo"),
        "source": add_die_source,
        "defaultSize": {"width": 540, "height": 320},
        "title": "How to add a Die",
        "popupId": "addDieHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "DuplicateDieHowTo"),
        "source": duplicate_die_source,
        "defaultSize": {"width": 580, "height": 400},
        "title": "How to duplicate a Die",
        "popupId": "duplicateDieHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "EditRankHowTo"),
        "source": edit_rank_source,
        "defaultSize": {"width": 520, "height": 300},
        "title": "How to edit a Die Rank",
        "popupId": "editRankHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "DieRanksHowTo"),
        "source": die_ranks_source,
        "defaultSize": {"width": 580, "height": 380},
        "title": "How to manage Die Ranks",
        "popupId": "dieRanksHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "LocationTypeEditorHowTo"),
        "source": location_type_editor_source,
        "defaultSize": {"width": 660, "height": 480},
        "title": "How to edit Location Type Definitions",
        "popupId": "locationTypeEditorHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "NewOperationTemplateHowTo"),
        "source": new_operation_template_source,
        "defaultSize": {"width": 560, "height": 360},
        "title": "How to create an Operation Template",
        "popupId": "newOperationTemplateHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "NewSpecModalHowTo"),
        "source": new_spec_modal_source,
        "defaultSize": {"width": 560, "height": 340},
        "title": "How to create a Quality Spec",
        "popupId": "newSpecModalHowTo",
        "builder": build_config_view,
    },
    {
        "dir": os.path.join(MPP_CONFIG_VIEWS, "Components", "Popups", "AddAttributeDefinitionHowTo"),
        "source": add_attribute_definition_source,
        "defaultSize": {"width": 540, "height": 320},
        "title": "How to add an Attribute Definition",
        "popupId": "addAttributeDefinitionHowTo",
        "builder": build_config_view,
    },
]


# ------------------------------------------------------------- emitting -----
# Designer rewrites < > & = ' as six-character unicode escapes inside JSON
# string values on its next save. Pre-escaping the same way means that save
# produces no diff, instead of rewriting the whole multi-kilobyte string.
_DESIGNER_ESCAPES = {"<": "u003c", ">": "u003e", "&": "u0026",
                     "=": "u003d", "'": "u0027"}


def _designer_escape(dumped):
    """Apply Designer's escaping to an already json.dumps-ed string literal."""
    out = dumped
    for ch, esc in _DESIGNER_ESCAPES.items():
        out = out.replace(ch, "\\" + esc)
    return out


def build_view(source_html, default_size, title, popup_id):
    """The popup view: a self-drawn header (title + Close) over one markdown
    component filling the body.

    NO `title=` KWARG ON THE CALLING system.perspective.openPopup(...). That
    kwarg (and `draggable=True`) is what puts Perspective's own native
    popup-window title bar on screen - light-themed chrome outside this
    view's DOM entirely, so nothing in here can recolor it. Every other MPP
    popup avoids it the same way: open plain (no title/draggable), draw the
    title + close affordance as ordinary view content instead. Reference:
    DieCastOverflow (opened by this same DieCastBody screen) and
    ConfirmUnsaved/ConfirmAction. Losing draggable/resizable is the
    trade-off; theme-ability is the win. See
    feedback_ignition_popup_title_is_native_chrome.md.

    props.source carries the text; props.markdown is the OPTIONS object and
    must set escapeHtml false or the operator reads raw tags."""
    return {
        "custom": {},
        "params": {"popupId": popup_id},
        "propConfig": {
            "params.popupId": {"paramDirection": "input"},
        },
        "props": {"defaultSize": default_size},
        "root": {
            "type": "ia.container.flex",
            "meta": {"name": "root"},
            "props": {
                "direction": "column",
                "style": {"classes": "modal"},
            },
            "children": [
                {
                    "type": "ia.container.flex",
                    "meta": {"name": "Header"},
                    "position": {"shrink": 0},
                    "props": {"style": {"classes": "modal-header"}},
                    "children": [
                        {
                            "type": "ia.display.label",
                            "meta": {"name": "Title"},
                            "position": {"grow": 1},
                            "props": {"text": title},
                        },
                        {
                            # mpp/cancel + .modal-close: the same X-icon close
                            # affordance as AppMenu's HeaderBar - dom.onClick,
                            # not a button, and Title's grow:1 (not this
                            # header's own space-between) is what pushes it
                            # to the far right, matching that reference.
                            "type": "ia.display.icon",
                            "meta": {"name": "CloseIcon"},
                            "props": {
                                "path": "mpp/cancel",
                                "style": {
                                    "classes": "modal-close",
                                    "cursor": "pointer",
                                    "height": "18px",
                                    "width": "18px",
                                },
                            },
                            "events": {
                                "dom": {
                                    "onClick": {
                                        "scope": "G",
                                        "type": "script",
                                        "config": {
                                            "script": (
                                                "\tsystem.perspective."
                                                "closePopup(id=self.view."
                                                "params.popupId)"
                                            )
                                        },
                                    }
                                }
                            },
                        },
                    ],
                },
                {
                    "type": "ia.container.flex",
                    "meta": {"name": "Body"},
                    "position": {"basis": "0px", "grow": 1},
                    "props": {"direction": "column", "style": {"classes": "modal-body"}},
                    "children": [
                        {
                            "type": "ia.display.markdown",
                            "meta": {"name": "Guide"},
                            "position": {"basis": "0px", "grow": 1},
                            "props": {
                                "source": source_html,
                                "markdown": {"escapeHtml": False},
                                "sectionSpacing": 8,
                                "style": {"fontSize": 13, "overflow": "auto"},
                            },
                        }
                    ],
                },
            ],
        },
    }


RESOURCE_JSON = {
    "scope": "G",
    "version": 1,
    "restricted": False,
    "overridable": True,
    "files": ["view.json"],
    "attributes": {
        "lastModification": {"actor": "claude", "timestamp": "2026-08-28T12:00:00Z"}
    },
}


# ------------------------------------------------------------- verifying ----
# Every one of these fails SILENTLY and TOTALLY in the running client, which is
# why they are worth a check rather than a look.
def verify(view, path):
    errs = []
    md = None

    def walk(o):
        nonlocal md
        if isinstance(o, dict):
            if o.get("type") == "ia.display.markdown":
                md = o
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    walk(view)
    if md is None:
        errs.append("no ia.display.markdown component")
        return errs

    props = md.get("props") or {}
    src = props.get("source")

    # empty source renders as a blank panel, with no error anywhere
    if not src or not str(src).strip():
        errs.append("props.source is empty")
        return errs

    # a string in props.markdown is the classic mix-up and renders nothing
    if isinstance(props.get("markdown"), str):
        errs.append("props.markdown is a string; the text belongs in props.source")

    # HTML with escapeHtml left true prints the tags to the operator
    if "<" in src:
        opts = props.get("markdown")
        if not isinstance(opts, dict) or opts.get("escapeHtml") is not False:
            errs.append("source contains HTML but markdown.escapeHtml is not false")

    # one unclosed tag swallows the rest of the guide and is invisible in a diff
    for tag in ("table", "tr", "td", "div", "span"):
        o = len(re.findall(r"<%s[\s>]" % tag, src))
        c = len(re.findall(r"</%s>" % tag, src))
        if o != c:
            errs.append("tag <%s> unbalanced: %d open, %d close" % (tag, o, c))

    return errs


def main():
    check_only = "--check" in sys.argv
    failed = False

    for g in GUIDES:
        src = g["source"]()
        builder = g.get("builder", build_view)
        view = builder(src, g["defaultSize"], g["title"], g["popupId"])
        name = os.path.basename(g["dir"])

        errs = verify(view, g["dir"])
        if errs:
            failed = True
            print("FAIL %s" % name)
            for e in errs:
                print("       %s" % e)
            continue
        print("ok   %-16s source %5d chars" % (name, len(src)))

        if check_only:
            continue

        os.makedirs(g["dir"], exist_ok=True)
        body = _designer_escape(json.dumps(view, indent=2, sort_keys=True,
                                           ensure_ascii=False))
        io.open(os.path.join(g["dir"], "view.json"), "w",
                encoding="utf-8", newline="\r\n").write(body + "\n")
        io.open(os.path.join(g["dir"], "resource.json"), "w",
                encoding="utf-8", newline="\r\n").write(
            json.dumps(RESOURCE_JSON, indent=2) + "\n")

    disk, n_paths = verify_on_disk()
    if disk:
        failed = True
        print("FAIL cross-file")
        for e in disk:
            print("       %s" % e)
    else:
        print("ok   cross-file      resource.json present; %d openPopup "
              "viewPath(s) resolve" % n_paths)

    if failed:
        sys.exit(1)
    print("--check: verified only, nothing written" if check_only else "written")




# ------------------------------------------------- cross-file verification --
# These two need the written files plus the screens that open them, so they run
# separately from verify() which only sees the view dict.
def verify_on_disk():
    """Checks that only make sense against the repo as a whole.

    Scripts are read from the PARSED json, not the raw text, so the six-char
    unicode escapes Designer writes are already decoded and the quote is just a
    quote. Regexing the raw file for an escaped quote is possible but the
    pattern is unreadable and easy to get wrong."""
    errs = []

    for g in GUIDES:
        name = os.path.basename(g["dir"])
        if not os.path.exists(os.path.join(g["dir"], "view.json")):
            errs.append("%s: view.json missing" % name)
            continue
        # a view folder with no resource.json is invisible to the gateway and
        # never renders, with no error anywhere
        if not os.path.exists(os.path.join(g["dir"], "resource.json")):
            errs.append("%s: resource.json missing - the gateway will not "
                        "see this view" % name)

    # Every openPopup viewPath must name a view that exists. A wrong path opens
    # nothing at all, silently, which is why this is worth checking.
    # Popup calls in this project use either quote style, so accept both -
    # a pattern that only matched one style would silently validate a fraction
    # of the call sites and look like it had checked them all.
    pat = re.compile(r"""openPopup\(\s*[^,]+,\s*(?:'([^']+)'|"([^"]+)")""")
    checked = 0
    for project_name in PROJECT_NAMES:
        proj = os.path.join(REPO, "ignition", "projects", project_name,
                            "com.inductiveautomation.perspective", "views")
        # A Perspective project INHERITS its parent's views, so a viewPath
        # absent from MPP/MPP_Config may still resolve from Core at runtime.
        # Resolving against one project alone reports inherited popups as
        # broken - ConfirmDestructive lives in Core and is used from both.
        search = _view_roots(project_name)
        for root, _dirs, files in os.walk(proj):
            if "view.json" not in files:
                continue
            try:
                view = json.load(io.open(os.path.join(root, "view.json"),
                                         encoding="utf-8"))
            except ValueError as e:
                errs.append("%s: view.json does not parse (%s)"
                            % (os.path.relpath(root, proj), e))
                continue

            scripts = []

            def collect(o):
                if isinstance(o, dict):
                    s = o.get("script")
                    if isinstance(s, str):
                        scripts.append(s)
                    for v in o.values():
                        collect(v)
                elif isinstance(o, list):
                    for v in o:
                        collect(v)

            collect(view)
            for s in scripts:
                for m in pat.finditer(s):
                    vpath = m.group(1) or m.group(2)
                    if not vpath.startswith("BlueRidge/"):
                        continue
                    checked += 1
                    if not any(os.path.exists(os.path.join(r, *vpath.split("/"),
                                                           "view.json"))
                               for r in search):
                        errs.append("%s/%s: openPopup targets '%s', which "
                                    "does not exist in %s or any parent "
                                    "project"
                                    % (project_name,
                                       os.path.relpath(root, proj), vpath,
                                       project_name))
    return errs, checked


def _view_roots(project):
    """The view directories a project can resolve a viewPath from: its own,
    then each ancestor named by project.json's "parent"."""
    roots = []
    seen = set()
    name = project
    while name and name not in seen:
        seen.add(name)
        base = os.path.join(REPO, "ignition", "projects", name)
        vdir = os.path.join(base, "com.inductiveautomation.perspective", "views")
        if os.path.isdir(vdir):
            roots.append(vdir)
        try:
            meta = json.load(io.open(os.path.join(base, "project.json"),
                                     encoding="utf-8"))
        except (IOError, ValueError):
            break
        name = meta.get("parent")
    return roots
if __name__ == "__main__":
    main()
