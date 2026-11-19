"""Harness for BlueRidge.Workorder.ScaleDigiWatcher -- the Digi One SP scale
feed -- under plain CPython, with the Ignition modules it imports (java.lang,
system.*) and the BlueRidge entities it calls stubbed.

    python tools/test_scale_digi_watcher.py

Spec: docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md

The record, one per GOOD press, as the TCP driver (Character Based, delimiter
CR) delivers it -- the previous record's two LFs at the front:

    \\n\\n(NET)15.5<UOM>LB<TWM>1<Part>TEST3\\r

What is proved here is the Python half: the parse, the order of the per-press
checks, what reaches SQL, and what lands in the InterfaceLog payload. The rules
(one held press per terminal, eligibility, no box mixing) are SQL's and are
tested in sql/tests/0134_ScaleDigi and sql/tests/0113_ScaleStation.
"""

import json
import os
import sys
import types
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "ignition", "projects", "Core", "ignition",
                       "script-python", "BlueRidge")
CODE = os.path.join(SCRIPTS, "Workorder", "ScaleDigiWatcher", "code.py")


def _stubModules():
    java = types.ModuleType("java")
    java.lang = types.ModuleType("java.lang")
    java.lang.Exception = Exception
    system = types.ModuleType("system")
    for name in ("date", "opc", "tag", "util", "perspective"):
        mod = types.ModuleType("system." + name)
        setattr(system, name, mod)
        sys.modules["system." + name] = mod
    system.util.jsonEncode = lambda obj: json.dumps(obj, sort_keys=True)
    sys.modules.update({"java": java, "java.lang": java.lang, "system": system})


def _loadFile(path, name):
    _stubModules()
    mod = types.ModuleType(name)
    with open(path, encoding="utf-8") as f:
        source = f.read()
    exec(compile(source, path, "exec"), mod.__dict__)
    return mod


def _load():
    return _loadFile(CODE, "ScaleDigiWatcher")


W = _load()

BENCH = "(NET)15.5<UOM>LB<TWM>1<Part>TEST3"


class ParseTests(unittest.TestCase):

    def test_bench_record(self):
        p = W.parse(BENCH)
        self.assertTrue(p["ok"])
        self.assertEqual(p["net"], 15.5)
        self.assertEqual(p["netText"], "15.5")
        self.assertEqual(p["uom"], "LB")
        self.assertEqual(p["twm"], 1)
        self.assertEqual(p["part"], "TEST3")

    def test_leading_lf_from_previous_record(self):
        p = W.parse("\n\n" + BENCH + "\r")
        self.assertTrue(p["ok"])
        self.assertEqual((p["net"], p["part"]), (15.5, "TEST3"))

    def test_fragments_reassembled(self):
        frags = ["(N", "ET)1", "5.5<U", "OM>LB<", "TWM>1<Pa", "rt>TEST3", "\r"]
        p = W.parse("".join(frags))
        self.assertTrue(p["ok"])
        self.assertEqual((p["net"], p["uom"], p["twm"], p["part"]), (15.5, "LB", 1, "TEST3"))

    def test_part_with_spaces_and_dashes(self):
        p = W.parse("(NET)18.2<UOM>LB<TWM>1<Part>12270-6NA -A000")
        self.assertEqual(p["part"], "12270-6NA -A000")

    def test_two_records_refused(self):
        p = W.parse(BENCH + "\r\n\n" + BENCH)
        self.assertFalse(p["ok"])
        self.assertIn("2", p["reason"])

    def test_no_record_refused(self):
        p = W.parse("\n\nhello\r")
        self.assertFalse(p["ok"])
        self.assertIn("no weighment", p["reason"])

    def test_none_refused(self):
        self.assertFalse(W.parse(None)["ok"])

    def test_malformed_record_refused(self):
        p = W.parse("(NET)abc<UOM>LB<TWM>1<Part>TEST3")
        self.assertFalse(p["ok"])

    def test_twm_zero_parsed(self):
        p = W.parse("(NET)15.5<UOM>LB<TWM>0<Part>TEST3")
        self.assertTrue(p["ok"])
        self.assertEqual(p["twm"], 0)

    def test_empty_part(self):
        p = W.parse("(NET)15.5<UOM>LB<TWM>1<Part>\r")
        self.assertTrue(p["ok"])
        self.assertEqual(p["part"], "")

    def test_negative_net(self):
        p = W.parse("(NET)-0.4<UOM>LB<TWM>1<Part>TEST3")
        self.assertTrue(p["ok"])
        self.assertEqual(p["net"], -0.4)

    def test_decode_signed_bytes(self):
        self.assertEqual(W.decodeBytes([40, 78, 69, 84, 41, -1]), "(NET)\xff")

    def test_decode_bench_bytes(self):
        raw = [10, 10] + [ord(c) for c in BENCH] + [13]
        self.assertEqual(W.parse(W.decodeBytes(raw))["part"], "TEST3")

    def test_decode_none(self):
        self.assertIsNone(W.decodeBytes(None))

    def test_digi_record_roundtrip(self):
        rec = W.digiRecord(15.5, "TEST3")
        self.assertTrue(rec.startswith("\n\n(NET)15.5<UOM>LB<TWM>1<Part>TEST3"))
        p = W.parse(rec)
        self.assertEqual((p["net"], p["twm"], p["part"]), (15.5, 1, "TEST3"))


SYS = 1
TERM = 106
PATH = "[MPP]PlcDevices/digiTest"


def _running(itemId=110, source="Default", openContainerId=None):
    return {"ItemId": itemId, "PartNumber": "FG-%s" % itemId, "Source": source,
            "OpenContainerId": openContainerId}


class Recorder(object):
    """Stands in for every BlueRidge entity the watcher calls, recording each
       call so a case can assert on it."""

    def __init__(self, items=None, running=None, pending=None, judge=None,
                 setResult=None, holdResult=None, closeResult=None, claimResult=None,
                 closeRaises=None, releaseResult=None):
        self.items = items or {}
        self.running = running or _running()
        self.pending = pending
        self.judgeRow = judge or {"Verdict": "Ok", "LowLimit": 14, "HighLimit": 17}
        self.setResult = setResult or {"Status": 1, "Message": "Running part set."}
        self.holdResult = holdResult or {"Status": 1, "Message": "Tray held.", "NewId": 9}
        self.closeResult = closeResult or {"Status": 1, "ContainerId": 77, "FinishedGoodLotId": 501}
        self.logs, self.alarms, self.closes, self.broadcasts = [], [], [], []
        self.sets, self.holds, self.judgeCalls, self.claims = [], [], [], []
        self.claimResult = claimResult or {"Status": 1, "Message": "Held press claimed."}
        self.closeRaises = closeRaises
        self.releaseResult = releaseResult or {"Status": 1}
        self.pressCalls = []

    def install(self, module):
        rec = self
        BR = types.SimpleNamespace()
        BR.Workorder = types.SimpleNamespace(
            PlcWatcher=types.SimpleNamespace(
                logInterface=lambda device, description, **kw:
                    rec.logs.append(dict(kw, device=device, description=description)),
                notifyAlarm=lambda terminal, title, message, level="error":
                    rec.alarms.append({"title": title, "message": message, "level": level}),
                broadcastPageMessage=lambda messageType, payload:
                    rec.broadcasts.append((messageType, payload))),
            ScaleEPrintWatcher=types.SimpleNamespace(
                _claim=lambda path, stamp, initial: rec.claims.append(stamp) or not initial),
            Assembly=types.SimpleNamespace(
                plcCompleteTray=rec._close),
            ScaleStation=types.SimpleNamespace(
                getRunningPartOrEmpty=lambda terminal: dict(rec.running),
                getPendingPressOrEmpty=lambda terminal: dict(rec.pending or {"Id": None}),
                setRunningPart=lambda terminal, itemId, appUserId=None:
                    rec.sets.append((terminal, itemId, appUserId)) or rec._setOutcome(itemId),
                holdPress=lambda terminal, net, uom, code, appUserId=None:
                    rec.holds.append((terminal, net, uom, code, appUserId)) or rec.holdResult,
                claimPress=lambda pid, appUserId=None:
                    rec.pressCalls.append(("claim", pid, appUserId)) or rec.claimResult,
                releasePress=lambda pid, appUserId=None:
                    rec.pressCalls.append(("release", pid, appUserId)) or rec.releaseResult,
                completePress=lambda pid, itemId, lotId, appUserId=None:
                    rec.pressCalls.append(("complete", pid, itemId, lotId, appUserId)) or {"Status": 1},
                discardPress=lambda pid, appUserId=None:
                    rec.pressCalls.append(("discard", pid, appUserId)) or {"Status": 1, "Message": "Held tray discarded."},
                scaleInstancePath=lambda terminal: PATH))
        BR.Parts = types.SimpleNamespace(
            ContainerConfig=types.SimpleNamespace(judgeWeight=rec._judge),
            Item=types.SimpleNamespace(getByPartNumber=lambda pn: rec.items.get(pn)))
        BR.Common = types.SimpleNamespace(
            Util=types.SimpleNamespace(log=lambda *a, **k: None, systemAppUserId=lambda: SYS))
        module.BlueRidge = BR

    def _close(self, terminal, method):
        self.closes.append(method)
        if self.closeRaises:
            raise self.closeRaises
        return self.closeResult

    def _setOutcome(self, itemId):
        if self.setResult.get("Status"):
            self.running = _running(itemId, "Override")
        return self.setResult

    def _judge(self, itemId, method, weight, scaleFlags=None):
        self.judgeCalls.append({"itemId": itemId, "method": method, "weight": weight})
        return dict(self.judgeRow)

    def payload(self, description="ByWeight tray close"):
        rows = [l for l in self.logs if l["description"] == description]
        return json.loads(rows[-1]["requestPayload"]) if rows else None

    def conditions(self):
        return [l.get("errorCondition") for l in self.logs if l.get("errorCondition")]


def _run(rec, message=BENCH):
    rec.install(W)
    return W.handleMessage(PATH, TERM, message)


class HandleMessageTests(unittest.TestCase):

    def test_match_same_part_closes(self):
        rec = Recorder(items={"TEST3": {"Id": 110}})
        r = _run(rec)
        self.assertEqual(r["Status"], 1)
        self.assertEqual(rec.sets, [])
        self.assertEqual(rec.closes, ["ByWeight"])
        p = rec.payload()
        self.assertEqual((p["v"], p["partSource"], p["scalePart"], p["twm"]), (2, "Scale", "TEST3", 1))
        self.assertEqual((p["verdict"], p["scaleVerdict"], p["mesVerdict"], p["agree"]), ("Ok", "Ok", "Ok", True))
        close = [l for l in rec.logs if l["description"] == "ByWeight tray close"][0]
        self.assertEqual((close["locationId"], close["itemId"], close["lotId"], close["ok"]), (TERM, 110, 501, True))

    def test_match_other_part_switches_then_closes(self):
        rec = Recorder(items={"TEST3": {"Id": 222}})
        r = _run(rec)
        self.assertEqual(rec.sets, [(TERM, 222, SYS)])
        self.assertEqual(r["Status"], 1)
        self.assertEqual(rec.judgeCalls[0]["itemId"], 222)

    def test_switch_refused_closes_nothing(self):
        rec = Recorder(items={"TEST3": {"Id": 222}},
                       setResult={"Status": 0, "Message": "Finish open box #5 first."})
        r = _run(rec)
        self.assertEqual(r["Status"], 0)
        self.assertEqual(rec.closes, [])
        self.assertEqual(rec.alarms[-1]["message"], "Finish open box #5 first.")
        self.assertEqual(rec.payload("Tray not closed")["scalePart"], "TEST3")

    def test_unknown_code_with_open_box_closes_with_warning(self):
        rec = Recorder(running=_running(110, "Default", openContainerId=5))
        r = _run(rec)
        self.assertEqual(r["Status"], 1)
        self.assertIn("ScaleFlagsPartUnknown", rec.conditions())
        self.assertEqual(rec.payload()["partSource"], "Running")
        self.assertEqual(rec.holds, [])

    def test_unknown_code_with_override_closes_with_warning(self):
        rec = Recorder(running=_running(110, "Override"))
        r = _run(rec)
        self.assertEqual(r["Status"], 1)
        self.assertIn("ScaleFlagsPartUnknown", rec.conditions())

    def test_unknown_code_with_scale_set_override_holds(self):
        # An override the SCALE set (SYS, after a matched code) is not an
        # operator's choice: a later unknown code must not close as that part.
        running = _running(110, "Override")
        running["OverrideSetBy"] = "SYS"
        rec = Recorder(running=running)
        r = _run(rec)
        self.assertTrue(r.get("Held"))
        self.assertEqual(rec.closes, [])

    def test_unknown_code_default_holds(self):
        rec = Recorder(running=_running(110, "Default"))
        r = _run(rec)
        self.assertTrue(r.get("Held"))
        self.assertEqual(r["Status"], 0)
        self.assertEqual(rec.holds, [(TERM, 15.5, "LB", "TEST3", SYS)])
        self.assertEqual(rec.closes, [])
        self.assertIn("ScaleFlagsHeld", rec.conditions())
        self.assertEqual(rec.alarms[-1]["level"], "warning")

    def test_unknown_code_nothing_runs_holds(self):
        rec = Recorder(running=_running(None, "None"))
        r = _run(rec)
        self.assertTrue(r.get("Held"))

    def test_hold_refused_is_a_refusal(self):
        rec = Recorder(running=_running(110, "Default"),
                       holdResult={"Status": 0, "Message": "A tray is already waiting", "NewId": None})
        r = _run(rec)
        self.assertEqual(r["Status"], 0)
        self.assertFalse(r.get("Held"))
        self.assertEqual(rec.closes, [])

    def test_deprecated_item_is_no_match(self):
        # Parts.Item.getByPartNumber returns None for a deprecated part, so the code
        # is treated as unknown: held when the running part is only a default.
        rec = Recorder(items={}, running=_running(110, "Default"))
        r = _run(rec)
        self.assertTrue(r.get("Held"))

    def test_empty_part_is_no_match(self):
        rec = Recorder(items={"": {"Id": 1}}, running=_running(110, "Override"))
        _run(rec, "(NET)15.5<UOM>LB<TWM>1<Part>\r")
        self.assertIn("ScaleFlagsPartUnknown", rec.conditions())

    def test_pending_blocks_press(self):
        rec = Recorder(items={"TEST3": {"Id": 110}}, pending={"Id": 9, "NetWeight": 15.5})
        r = _run(rec)
        self.assertEqual(r["Status"], 0)
        self.assertEqual(rec.alarms[-1]["title"], "Tray waiting for its part")
        self.assertEqual((rec.holds, rec.closes, rec.sets), ([], [], []))

    def test_twm_zero_refused(self):
        rec = Recorder(items={"TEST3": {"Id": 110}})
        r = _run(rec, "(NET)15.5<UOM>LB<TWM>0<Part>TEST3")
        self.assertEqual(r["Status"], 0)
        self.assertEqual(rec.alarms[-1]["title"], "Scale did not pass this tray")
        self.assertEqual(rec.closes, [])

    def test_wrong_units_refused(self):
        rec = Recorder(items={"TEST3": {"Id": 110}})
        r = _run(rec, "(NET)7.0<UOM>KG<TWM>1<Part>TEST3")
        self.assertEqual(rec.alarms[-1]["title"], "Scale is in the wrong units")
        self.assertEqual(rec.closes, [])

    def test_lowercase_lb_accepted(self):
        rec = Recorder(items={"TEST3": {"Id": 110}})
        r = _run(rec, "(NET)15.5<UOM>lb<TWM>1<Part>TEST3")
        self.assertEqual(r["Status"], 1)

    def test_mes_mismatch_logs_warning_and_closes(self):
        rec = Recorder(items={"TEST3": {"Id": 110}},
                       judge={"Verdict": "Under", "LowLimit": 16, "HighLimit": 18, "Message": "1.0 lb under"})
        r = _run(rec)
        self.assertEqual(r["Status"], 1)
        self.assertIn("ScaleFlagsMesMismatch", rec.conditions())
        p = rec.payload()
        self.assertEqual((p["mesVerdict"], p["agree"], p["verdict"]), ("Under", False, "Ok"))

    def test_mes_noconfig_agree_none(self):
        rec = Recorder(items={"TEST3": {"Id": 110}}, judge={"Verdict": "NoConfig", "Message": "no target"})
        _run(rec)
        self.assertIsNone(rec.payload()["agree"])
        self.assertIn("ScaleFlagsMesMismatch", rec.conditions())

    def test_close_failure_alarms(self):
        rec = Recorder(items={"TEST3": {"Id": 110}}, closeResult={"Status": 0, "Message": "No stock"})
        r = _run(rec)
        self.assertEqual(r["Status"], 0)
        self.assertEqual(rec.alarms[-1]["message"], "No stock")

    def test_unreadable_message_refused(self):
        rec = Recorder()
        r = _run(rec, None)
        self.assertEqual(r["Status"], 0)
        self.assertEqual(rec.alarms[-1]["title"], "Scale weighment not read")

    def test_unparseable_message_refused(self):
        rec = Recorder()
        _run(rec, "\n\ngarbage\r")
        self.assertEqual(rec.alarms[-1]["title"], "Scale weighment not understood")

    def test_broadcast_on_every_outcome(self):
        for msg in (BENCH, None, "(NET)15.5<UOM>LB<TWM>0<Part>TEST3"):
            rec = Recorder(items={"TEST3": {"Id": 110}})
            _run(rec, msg)
            self.assertEqual(rec.broadcasts, [("scalePressRecorded", {"terminalLocationId": TERM})])

    def test_on_receive_skips_initial_change(self):
        rec = Recorder()
        rec.install(W)
        self.assertIsNone(W.onReceive(PATH, TERM, object(), initialChange=True))
        self.assertEqual(rec.closes, [])

OPERATOR = 42
HELD = {"Id": 9, "NetWeight": 15.5, "Uom": "LB", "ScalePartCode": "TEST3"}


class PickTests(unittest.TestCase):

    def _pick(self, rec, itemId=110):
        rec.install(W)
        return W.pickPart(9, TERM, itemId, OPERATOR)

    def test_pick_closes_and_completes(self):
        rec = Recorder(pending=dict(HELD))
        r = self._pick(rec)
        self.assertEqual(r["Status"], 1)
        self.assertEqual(rec.pressCalls, [("claim", 9, OPERATOR), ("complete", 9, 110, 501, OPERATOR)])
        p = rec.payload()
        self.assertEqual((p["partSource"], p["net"], p["scalePart"], p["heldId"]), ("Picked", 15.5, "TEST3", 9))
        self.assertEqual(rec.broadcasts, [("scalePressRecorded", {"terminalLocationId": TERM})])

    def test_pick_switches_part_when_different(self):
        rec = Recorder(pending=dict(HELD))
        self._pick(rec, itemId=222)
        self.assertEqual(rec.sets, [(TERM, 222, OPERATOR)])
        self.assertEqual(rec.pressCalls[-1][0:3], ("complete", 9, 222))

    def test_pick_claim_refused_closes_nothing(self):
        rec = Recorder(pending=dict(HELD), claimResult={"Status": 0, "Message": "This tray has already been dealt with."})
        r = self._pick(rec)
        self.assertEqual(r["Status"], 0)
        self.assertEqual((rec.closes, rec.sets), ([], []))

    def test_pick_with_nothing_pending_refused(self):
        rec = Recorder(pending=None)
        r = self._pick(rec)
        self.assertEqual(r["Status"], 0)
        self.assertEqual((rec.pressCalls, rec.closes), ([], []))

    def test_pick_close_failure_releases(self):
        rec = Recorder(pending=dict(HELD), closeResult={"Status": 0, "Message": "No stock"})
        r = self._pick(rec)
        self.assertEqual(r["Status"], 0)
        self.assertEqual([c[0] for c in rec.pressCalls], ["claim", "release"])

    def test_pick_close_exception_releases(self):
        rec = Recorder(pending=dict(HELD), closeRaises=RuntimeError("deadlock victim"))
        r = self._pick(rec)
        self.assertEqual(r["Status"], 0)
        self.assertEqual([c[0] for c in rec.pressCalls], ["claim", "release"])
        self.assertIn("deadlock victim", r["Message"])
        self.assertEqual(rec.broadcasts, [("scalePressRecorded", {"terminalLocationId": TERM})])

    def test_pick_release_failure_alarms(self):
        rec = Recorder(pending=dict(HELD), closeResult={"Status": 0, "Message": "No stock"},
                       releaseResult={"Status": 0, "Message": "Only a claimed press"})
        r = self._pick(rec)
        self.assertEqual(r["Status"], 0)
        self.assertEqual(rec.alarms[-1]["title"], "Held tray could not be put back")
        self.assertEqual(rec.alarms[-1]["level"], "error")

    def test_pick_switch_refused_releases(self):
        rec = Recorder(pending=dict(HELD), setResult={"Status": 0, "Message": "Finish open box #5 first."})
        r = self._pick(rec, itemId=222)
        self.assertEqual(r["Message"], "Finish open box #5 first.")
        self.assertEqual([c[0] for c in rec.pressCalls], ["claim", "release"])
        self.assertEqual(rec.closes, [])

    def test_discard(self):
        rec = Recorder(pending=dict(HELD))
        rec.install(W)
        r = W.discardPress(9, TERM, OPERATOR)
        self.assertEqual(r["Status"], 1)
        self.assertEqual(rec.pressCalls, [("discard", 9, OPERATOR)])
        self.assertEqual(rec.broadcasts, [("scalePressRecorded", {"terminalLocationId": TERM})])


STATION = os.path.join(SCRIPTS, "Workorder", "ScaleStation", "code.py")


def _station(devices=None, pendingRow=None, parts=None):
    s = _loadFile(STATION, "ScaleStation")
    calls = []
    s.BlueRidge = types.SimpleNamespace(
        Common=types.SimpleNamespace(
            Util=types.SimpleNamespace(extractQualifiedValues=lambda v: v, requireAppUserId=lambda v: v),
            Db=types.SimpleNamespace(
                execOne=lambda nq, p: calls.append((nq, p)) or pendingRow,
                execMutation=lambda nq, p: calls.append((nq, p)) or {"Status": 1, "Message": "ok"})),
        Location=types.SimpleNamespace(TerminalPlcDevice=types.SimpleNamespace(
            getByTerminal=lambda tid: list(devices or []))))
    s.listEligibleParts = lambda tid, _token=None: list(parts or [])
    return s, calls


class StationTests(unittest.TestCase):

    def test_scale_instance_path_finds_digi(self):
        s, _ = _station(devices=[{"DeviceTypeCode": "TrayInspectionStation", "UdtInstancePath": "x"},
                                 {"DeviceTypeCode": "ScaleStationDigi", "UdtInstancePath": "[MPP]PlcDevices/digiTest"}])
        self.assertEqual(s.scaleInstancePath(106), "[MPP]PlcDevices/digiTest")

    def test_scale_instance_path_still_finds_eprint(self):
        s, _ = _station(devices=[{"DeviceTypeCode": "ScaleStationEPrint", "UdtInstancePath": "[MPP]PlcDevices/Scale"}])
        self.assertEqual(s.scaleInstancePath(106), "[MPP]PlcDevices/Scale")

    def test_pending_empty_shape(self):
        s, calls = _station(pendingRow=None)
        p = s.getPendingPressOrEmpty(106)
        self.assertIsNone(p["Id"])
        self.assertEqual(sorted(p.keys()), ["Id", "NetWeight", "ReceivedAtEt", "ScalePartCode", "Uom"])
        self.assertEqual(calls, [("workorder/ScalePendingPress_GetForTerminal", {"terminalLocationId": 106})])

    def test_pending_row(self):
        s, _ = _station(pendingRow=dict(HELD, ReceivedAtEt=None, TerminalLocationId=106))
        self.assertEqual(s.getPendingPressOrEmpty(106)["ScalePartCode"], "TEST3")

    def test_hold_press_params(self):
        s, calls = _station()
        s.holdPress(106, 15.5, "LB", "TEST3", appUserId=1)
        self.assertEqual(calls, [("workorder/ScalePendingPress_Hold",
                                  {"terminalLocationId": 106, "netWeight": 15.5, "uom": "LB",
                                   "scalePartCode": "TEST3", "appUserId": 1})])

    def test_press_mutations_nq_names(self):
        s, calls = _station()
        s.claimPress(9, appUserId=2); s.releasePress(9, appUserId=2)
        s.completePress(9, 110, 501, appUserId=2); s.discardPress(9, appUserId=2)
        self.assertEqual([c[0] for c in calls], ["workorder/ScalePendingPress_Claim", "workorder/ScalePendingPress_Release",
                                                 "workorder/ScalePendingPress_Complete", "workorder/ScalePendingPress_Discard"])
        self.assertEqual(calls[2][1], {"id": 9, "itemId": 110, "finishedGoodLotId": 501, "appUserId": 2})

    def test_pending_part_buttons(self):
        s, _ = _station(parts=[{"ItemId": 5, "PartNumber": "12270-6NA -A000", "Description": "Fuel pump"}])
        self.assertEqual(s.pendingPartButtons(106, 9),
                         [{"terminalLocationId": 106, "pendingId": 9, "itemId": 5,
                           "label": "12270-6NA -A000  Fuel pump"}])

    def test_apply_pending_pick_coerces_text_ids(self):
        # A page URL parameter arrives as text ("106"); the close-context
        # lookup compares numbers, so the pick must pass numbers.
        s, _ = _station()
        seen = []
        s.BlueRidge.Workorder = types.SimpleNamespace(ScaleDigiWatcher=types.SimpleNamespace(
            pickPart=lambda pid, tid, item, user: seen.append((pid, tid, item, user)) or {"Status": 1},
            discardPress=lambda pid, tid, user: seen.append((pid, tid, user)) or {"Status": 1}))
        s.BlueRidge.Common.Session = types.SimpleNamespace(currentAppUserId=lambda session: 2)
        s.BlueRidge.Common.Ui = types.SimpleNamespace(notifyResult=lambda r, t: None)
        s.applyPendingPick(None, "106", "9", "110")
        s.applyPendingDiscard(None, "106", "9")
        self.assertEqual(seen, [(9, 106, 110, 2), (9, 106, 2)])

    def test_pending_part_buttons_none_without_pending(self):
        s, _ = _station(parts=[{"ItemId": 5, "PartNumber": "P", "Description": "D"}])
        self.assertEqual(s.pendingPartButtons(106, None), [])

    def test_has_pending(self):
        self.assertTrue(_station(pendingRow={"Id": 9})[0].hasPendingPress(106))
        self.assertFalse(_station(pendingRow=None)[0].hasPendingPress(106))

    def test_pending_banner_text(self):
        s, _ = _station(pendingRow={"Id": 9, "NetWeight": 15.5, "Uom": "LB", "ScalePartCode": "TEST3"})
        self.assertEqual(s.pendingBannerText(106),
                         "Tray waiting: 15.5 LB. The scale said 'TEST3', which is not a part here. "
                         "Choose the part to close it:")


class _QV(object):
    def __init__(self, value):
        self.value = value
        self.quality = types.SimpleNamespace(isGood=lambda: True)


class DispatchTests(unittest.TestCase):

    def _dispatch(self, deviceType):
        mod = _loadFile(os.path.join(SCRIPTS, "Workorder", "PlcWatcher", "code.py"), "PlcWatcher")
        calls = []
        row = {"DeviceTypeCode": deviceType, "TerminalLocationId": TERM}
        mod.BlueRidge = types.SimpleNamespace(
            Location=types.SimpleNamespace(TerminalPlcDevice=types.SimpleNamespace(
                getByInstancePath=lambda p: [row] if p == PATH else [])),
            Common=types.SimpleNamespace(Util=types.SimpleNamespace(
                log=lambda *a, **k: calls.append(("log",) + a),
                extractQualifiedValues=lambda v: v)),
            Workorder=types.SimpleNamespace(
                ScaleEPrintWatcher=types.SimpleNamespace(
                    onReceive=lambda *a: calls.append(("eprint",) + a)),
                ScaleDigiWatcher=types.SimpleNamespace(
                    onReceive=lambda *a: calls.append(("digi",) + a))))
        mod.dispatchMessage(PATH + "/LastReceiveTime", None, _QV("stamp"), False)
        return [c for c in calls if c[0] != "log"]

    def test_routes_digi(self):
        self.assertEqual(self._dispatch("ScaleStationDigi"), [("digi", PATH, TERM, "stamp", False)])

    def test_routes_eprint_unchanged(self):
        self.assertEqual(self._dispatch("ScaleStationEPrint"), [("eprint", PATH, TERM, "stamp", False)])

    def test_other_type_ignored(self):
        self.assertEqual(self._dispatch("TrayInspectionStation"), [])


if __name__ == "__main__":
    unittest.main()
