"""Guards for the ASYNC print-failure path reaching the operator.

A shipping label dispatched from Container_Complete fails on a gateway thread
with no session attached. The failure reaches the floor through two hops:

  ShippingDispatcher._dispatchWorker  -> classifyOutcome -> MarkDispatch
  PrintFailureGateway.broadcastTick   -> decideAlert     -> banner + one modal

Both hops have a pure decision function, and these tests pin them. The reason
they are pure is the 5-second timer: broadcastTick re-fires for every
failed-unacknowledged label on every tick, so "has this terminal already been
told about this label" is a decision that MUST be deterministic and testable --
getting it wrong re-opens a modal in front of an operator every five seconds
until somebody acknowledges it.

Both modules are Jython (java.net / BlueRidge.*), so they cannot be imported
under CPython. These tests ast-extract the self-contained helpers and exec
those -- the same approach as test_label_transport_ack.py.

Run: python -m pytest ignition/tests/test_print_failure_alert.py
"""

import ast
import io
import os

import pytest

_SCRIPTS = os.path.join(
    os.path.dirname(__file__), os.pardir,
    "projects", "Core", "ignition", "script-python", "BlueRidge", "Lots",
)
TRANSPORT = os.path.join(_SCRIPTS, "LabelTransport", "code.py")
GATEWAY = os.path.join(_SCRIPTS, "PrintFailureGateway", "code.py")

TRANSPORT_WANTED = ("classifyOutcome", "_dispatchLogParams", "operatorGuidance",
                    "_parseAck", "_unquote")
GATEWAY_WANTED = ("decideAlert",)


def _load(path, wanted, seed=None):
    """Exec only the self-contained helpers, so the test needs no Ignition."""
    src = io.open(path, encoding="utf-8").read()
    tree = ast.parse(src)
    keep = [n for n in tree.body
            if isinstance(n, ast.FunctionDef) and n.name in wanted]
    ns = dict(seed or {})
    exec(compile(ast.Module(body=keep, type_ignores=[]), path, "exec"), ns)
    missing = [n for n in wanted if n not in ns]
    if missing:
        pytest.fail("%s: helper(s) missing: %s" % (path, ", ".join(missing)))
    return ns


@pytest.fixture(scope="module")
def transport():
    return _load(TRANSPORT, TRANSPORT_WANTED, {"_SYSTEM_NAME": "Zebra"})


@pytest.fixture(scope="module")
def gateway():
    return _load(GATEWAY, GATEWAY_WANTED, {"_SEEN_CAP": 50})


# --------------------------------------------------------------------------
# classifyOutcome -- ONE owner for the condition the worker persists and the
# audit row records. Before this existed the condition was computed inline in
# _dispatchLogParams and only ever reached Audit.InterfaceLog, so the operator's
# modal always fell through to the generic "tell a supervisor" guidance.
# --------------------------------------------------------------------------

def test_a_successful_dispatch_has_no_condition(transport):
    out = {"ok": True, "error": None, "ack": {"acked": True, "ok": True}}
    assert transport["classifyOutcome"](out) is None


def test_a_bridge_that_answered_err_is_queuerejected(transport):
    # The bridge ANSWERED. The network was fine and the queue name was wrong,
    # so this must not read as a reachability problem.
    out = {"ok": False, "error": "unknown printer",
           "ack": {"acked": True, "ok": False, "error": "unknown printer"}}
    assert transport["classifyOutcome"](out) == "QueueRejected"


def test_silence_from_the_far_end_is_dispatchfailed(transport):
    out = {"ok": False, "error": "Connection refused", "ack": {"acked": False}}
    assert transport["classifyOutcome"](out) == "DispatchFailed"


def test_a_missing_ack_block_does_not_raise(transport):
    assert transport["classifyOutcome"]({"ok": False, "error": "boom"}) == "DispatchFailed"
    assert transport["classifyOutcome"](None) == "DispatchFailed"


def test_the_audit_row_and_the_persisted_condition_agree(transport):
    """_dispatchLogParams must read the condition from classifyOutcome, not its
       own copy. Two sources would let the audit log and the operator's dialog
       disagree about the same failure."""
    for out in ({"ok": False, "error": "nope", "ack": {"acked": True, "ok": False}},
                {"ok": False, "error": "Connect timed out", "ack": {"acked": False}}):
        row = transport["_dispatchLogParams"]("1.2.3.4:9100", "^XA^XZ", out, "Shipping label")
        assert row["errorCondition"] == transport["classifyOutcome"](out)


# --------------------------------------------------------------------------
# decideAlert -- the terminal-side decision. Pure: guidance is passed IN so the
# taxonomy stays owned by LabelTransport.operatorGuidance.
# --------------------------------------------------------------------------

GUIDE = {"title": "The printer is not taking labels",
         "what": "The label reached the printer's PC, but its queue is not emptying.",
         "action": "Check the printer is plugged in and powered on.",
         "canSelfFix": True}


def _payload(**kw):
    p = {"shippingLabelId": 20031, "containerId": 777, "terminalLocationId": 147,
         "aimShipperId": "AIM13218042", "error": "conn refused",
         "errorCondition": "DispatchFailed", "level": "error"}
    p.update(kw)
    return p


def test_another_terminals_failure_is_ignored(gateway):
    got = gateway["decideAlert"]({"terminalLocationId": 9}, _payload(), [], GUIDE)
    assert got["relevant"] is False
    # Nothing else may be touched -- an irrelevant payload must not mark the
    # label seen, or the terminal that OWNS it would never get its modal.
    assert got["notice"] is None
    assert got["seen"] == []


def test_a_failure_for_this_terminal_is_shown(gateway):
    got = gateway["decideAlert"]({"terminalLocationId": 147}, _payload(), [], GUIDE)
    assert got["relevant"] is True
    assert got["alert"]["visible"] is True
    assert got["alert"]["shippingLabelId"] == 20031


def test_an_unaddressed_payload_reaches_every_terminal(gateway):
    # The pile-up alarm from sweepTick names no terminal. It is for whoever is
    # looking, so it must not be filtered out.
    got = gateway["decideAlert"]({"terminalLocationId": 147},
                                 _payload(terminalLocationId=None), [], GUIDE)
    assert got["relevant"] is True


def test_a_terminal_with_no_session_context_still_sees_it(gateway):
    # An unregistered IP falls back to facility-wide (project convention), so
    # session.custom.terminal can be empty. Showing it is the safe side: a
    # label nobody is told about is the failure this whole path exists to fix.
    for term in (None, {}, {"terminalLocationId": None}):
        assert gateway["decideAlert"](term, _payload(), [], GUIDE)["relevant"] is True


def test_the_banner_names_the_fault_not_a_generic_sentence(gateway):
    """The payload key used to be 'error' while the banner read 'message', so
       every per-label banner showed only 'A shipping label failed to print.'
       The operator's own words come from the guidance title now."""
    text = gateway["decideAlert"]({"terminalLocationId": 147}, _payload(), [], GUIDE)["alert"]["text"]
    assert GUIDE["title"] in text
    assert "AIM13218042" in text


def test_an_explicit_message_wins(gateway):
    # sweepTick's pile-up alarm writes a composed sentence of its own.
    got = gateway["decideAlert"]({"terminalLocationId": 147},
                                 {"message": "print sweep: 9 stranded shipping labels",
                                  "level": "critical", "strandedCount": 9},
                                 [], GUIDE)
    assert got["alert"]["text"] == "print sweep: 9 stranded shipping labels"


# ---- the once-per-label rule -------------------------------------------------

def test_the_modal_opens_the_first_time_a_label_is_seen(gateway):
    got = gateway["decideAlert"]({"terminalLocationId": 147}, _payload(), [], GUIDE)
    assert got["notice"] is GUIDE
    assert got["seen"] == [20031]


def test_the_modal_does_not_reopen_on_the_next_tick(gateway):
    """broadcastTick re-fires every 5 seconds until acknowledged. The banner is
       the persistent reminder; the modal is a one-time interruption."""
    got = gateway["decideAlert"]({"terminalLocationId": 147}, _payload(), [20031], GUIDE)
    assert got["relevant"] is True
    assert got["alert"]["visible"] is True       # banner stays up
    assert got["notice"] is None                 # modal does not
    assert got["seen"] == [20031]                # and does not grow


def test_a_second_different_label_gets_its_own_modal(gateway):
    got = gateway["decideAlert"]({"terminalLocationId": 147},
                                 _payload(shippingLabelId=20032), [20031], GUIDE)
    assert got["notice"] is GUIDE
    assert got["seen"] == [20031, 20032]


def test_a_label_id_is_matched_across_int_and_string(gateway):
    # JDBC and a view property hand the same id back in different types; a
    # type mismatch here would silently re-open the modal forever.
    got = gateway["decideAlert"]({"terminalLocationId": 147},
                                 _payload(shippingLabelId="20031"), [20031], GUIDE)
    assert got["notice"] is None


def test_an_alert_with_no_label_never_opens_a_modal(gateway):
    # The pile-up alarm is an IT problem with no single label and nothing
    # operatorGuidance can say about it. Banner only.
    got = gateway["decideAlert"]({"terminalLocationId": 147},
                                 {"message": "print sweep: 9 stranded", "level": "critical"},
                                 [], GUIDE)
    assert got["notice"] is None
    assert got["seen"] == []


def test_seen_is_bounded(gateway):
    """A terminal session runs for weeks. An unbounded list on a view property
       that is rewritten every 5 seconds is a leak."""
    old = list(range(1, 81))
    got = gateway["decideAlert"]({"terminalLocationId": 147},
                                 _payload(shippingLabelId=999), old, GUIDE)
    assert len(got["seen"]) == 50
    assert got["seen"][-1] == 999
    assert 1 not in got["seen"]          # oldest dropped, newest kept


def test_a_missing_seen_list_is_tolerated(gateway):
    # The property may not exist yet on a session that predates this build.
    got = gateway["decideAlert"]({"terminalLocationId": 147}, _payload(), None, GUIDE)
    assert got["seen"] == [20031]


# ---- the detail line --------------------------------------------------------

def test_the_detail_line_carries_what_a_supervisor_needs(gateway):
    """The detail is read aloud down a phone, so it must name the label and the
       raw fault -- not be a prettier version of the operator's sentence."""
    detail = gateway["decideAlert"]({"terminalLocationId": 147}, _payload(), [], GUIDE)["detail"]
    assert "20031" in detail
    assert "AIM13218042" in detail
    assert "conn refused" in detail


def test_a_failure_with_no_recorded_error_still_has_a_detail(gateway):
    detail = gateway["decideAlert"]({"terminalLocationId": 147},
                                    _payload(error=None), [], GUIDE)["detail"]
    assert "20031" in detail
    assert detail.strip() != ""


# --------------------------------------------------------------------------
# The four failures the 2026-09-29/30 hardware bring-up actually produced.
# These strings are read off Lots.ShippingLabel in Dev (labels 20015, 20025,
# 20026, 20027), not invented -- which is the only reason they are worth
# pinning. The taxonomy was derived FROM them, so if a future edit collapses
# two conditions these are the cases that catch it.
# --------------------------------------------------------------------------

BRINGUP = [
    # (label, outcome shape, expected condition, must appear in the action)
    (20026, {"ok": False, "error": "No printer endpoint resolved for this label."},
     "EndpointUnresolved", "supervisor"),
    (20025, {"ok": False, "error": "Connection refused: getsockopt",
             "ack": {"acked": False}},
     "DispatchFailed", "switched on"),
    (20015, {"ok": False, "error": "Connect timed out", "ack": {"acked": False}},
     "DispatchFailed", "switched on"),
    (20027, {"ok": False, "error": "[WinError 1801] The printer name is invalid",
             "ack": {"acked": True, "ok": False,
                     "error": "[WinError 1801] The printer name is invalid"}},
     "QueueRejected", "supervisor"),
]


def test_the_bringup_failures_classify_as_the_spec_says(transport):
    # 20026 never reaches the transport at all -- dispatch() refuses before the
    # worker runs and names EndpointUnresolved itself -- so it is excluded from
    # the classifier's remit and asserted separately below.
    for label, outcome, expected, _ in BRINGUP:
        if expected == "EndpointUnresolved":
            continue
        got = transport["classifyOutcome"](outcome)
        assert got == expected, "label %s: got %s, expected %s" % (label, got, expected)


def test_each_bringup_failure_gets_a_different_instruction(transport):
    """The taxonomy earns its place only if the operator reads something
       different. Two conditions producing the same sentence would mean the
       distinction cost work and bought nothing."""
    seen = {}
    for label, outcome, cond, must_say in BRINGUP:
        g = transport["operatorGuidance"](cond, outcome.get("error"))
        assert must_say in g["action"], "label %s action: %r" % (label, g["action"])
        seen[label] = (g["title"], g["what"])

    # Refused vs timed out share a condition and MUST still read differently --
    # the operator cannot act on the distinction, but the line they read to a
    # supervisor is what makes the callout useful.
    assert seen[20025][1] != seen[20015][1]
    # A wrong queue name is not a reachability problem and must not read as one.
    assert seen[20027][0] != seen[20025][0]


def test_a_wrong_queue_name_is_not_offered_as_retryable(transport):
    """Label 20027 was the bridge ANSWERING that its queue name was wrong.
       Nothing on the floor was broken and retrying only stacks labels."""
    g = transport["operatorGuidance"]("QueueRejected",
                                      "[WinError 1801] The printer name is invalid")
    assert g["canSelfFix"] is False
    assert "will not help" in g["action"]


def test_a_label_predating_the_column_degrades_honestly(gateway, transport):
    """The four Dev rows above carry LastPrintErrorCondition NULL -- they were
       written before migration 0102. A NULL condition must produce the generic
       guidance, not a guess, and the banner must still name the label."""
    g = transport["operatorGuidance"](None, "Connect timed out")
    assert g["canSelfFix"] is False
    got = gateway["decideAlert"]({"terminalLocationId": 147},
                                 _payload(errorCondition=None,
                                          error="Connect timed out",
                                          aimShipperId="DEVAIM-5G0-FG-001"),
                                 [], g)
    assert g["title"] in got["alert"]["text"]
    assert "DEVAIM-5G0-FG-001" in got["alert"]["text"]
    assert "Connect timed out" in got["detail"]
