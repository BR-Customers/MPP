"""Harness for BlueRidge.Workorder.ScaleEPrintWatcher -- runs the watcher's
parse() and handleMessage() under plain CPython, with the Ignition modules it
imports (java.lang, system.*) and the BlueRidge entities it calls stubbed.

    python tools/test_scale_eprint_watcher.py

What it proves is the transport half only: what the parser pulls out of a
printed record, what reaches judgeWeight, what lands in the InterfaceLog
payload, and that the scale's flags never change whether a tray closes. The
verdict and the flag comparison are SQL's and are tested in
sql/tests/0008_Parts_Item/029_ContainerConfig_JudgeWeight.sql; here the judge
is a stub that returns whatever row a case gives it.
"""

import json
import os
import sys
import types
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CODE = os.path.join(ROOT, "ignition", "projects", "Core", "ignition",
                    "script-python", "BlueRidge", "Workorder",
                    "ScaleEPrintWatcher", "code.py")


def _stubModules():
    java = types.ModuleType("java")
    java.lang = types.ModuleType("java.lang")
    java.lang.Exception = Exception
    system = types.ModuleType("system")
    for name in ("date", "opc", "tag", "util"):
        mod = types.ModuleType("system." + name)
        setattr(system, name, mod)
        sys.modules["system." + name] = mod
    system.util.jsonEncode = lambda obj: json.dumps(obj, sort_keys=True)
    sys.modules.update({"java": java, "java.lang": java.lang, "system": system})


class Recorder(object):
    """Stands in for every BlueRidge entity the watcher calls, recording each
       call so a case can assert on it."""

    def __init__(self, judgeRow=None, closeResult=None, ctx=None):
        self.logs = []
        self.alarms = []
        self.judgeCalls = []
        self.closes = []
        self.broadcasts = []
        self.judgeRow = judgeRow
        self.closeResult = closeResult or {"Status": 1, "ContainerId": 77}
        self.ctx = ctx or {"finishedGoodItemId": 110}

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
            Assembly=types.SimpleNamespace(
                resolvePlcCloseContext=lambda terminal, method: rec.ctx,
                plcCompleteTray=lambda terminal, method:
                    rec.closes.append(method) or rec.closeResult))
        BR.Parts = types.SimpleNamespace(
            ContainerConfig=types.SimpleNamespace(judgeWeight=rec._judge))
        BR.Common = types.SimpleNamespace(
            Util=types.SimpleNamespace(log=lambda *a, **k: None))
        module.BlueRidge = BR

    def _judge(self, itemId, method, weight, scaleFlags=None):
        self.judgeCalls.append({"itemId": itemId, "method": method,
                                "weight": weight, "scaleFlags": scaleFlags})
        return dict(self.judgeRow)


def _load():
    _stubModules()
    mod = types.ModuleType("ScaleEPrintWatcher")
    with open(CODE) as f:
        source = f.read()
    exec(compile(source, CODE, "exec"), mod.__dict__)
    return mod


W = _load()

# The Template 1 head (no flags) and the Template 3 head (flags, no trailing
# line break), in the layout the terminal prints them. See the note on
# FIXTURES_VERIFIED below.
T1 = "      35.13 lb \r\n      16.93 lb T \r\n      18.20 lb N \r\n"
T1_CAM = "      35.13 lb \r\n      16.93 lb T \r\n      18.20 lb N \r\nCAM=1"
T3_OK = "      66.0 lb \r\n      16.0 lb T \r\n      50.0 lb N \r\nUNDER: 0 OVER: 0 OK: 1"
T3_UNDER = "      56.0 lb \r\n      49.8 lb T \r\n       6.2 lb N \r\nUNDER: 1 OVER: 0 OK: 0"
T3_ZERO = "      66.0 lb \r\n      16.0 lb T \r\n      50.0 lb N \r\nUNDER: 0 OVER: 0 OK: 0"

# Verified 2026-10-19 on the office scale (B913444851) on Dev. Four real
# Template 3 prints were each 74 bytes (MessageBytes), the exact length of this
# fixed-width layout, and the live watcher parsed a real Message into
# flags=UNDER:0,OVER:0,OK:1 and closed the tray (Audit.InterfaceLog Id 38).
FIXTURES_VERIFIED = True


def _row(verdict="Ok", scale=None, agree=None, flagsMessage=None):
    return {"Verdict": verdict, "Message": "msg for %s" % verdict,
            "LowLimit": 48.0, "HighLimit": 52.0,
            "ScaleVerdict": scale, "FlagsAgree": agree, "FlagsMessage": flagsMessage}


class ParseTests(unittest.TestCase):

    def test_template1_has_no_flags(self):
        p = W.parse(T1)
        self.assertTrue(p["ok"])
        self.assertEqual(p["netText"], "18.20")
        self.assertIsNone(p["flags"])
        self.assertIsNone(p["cam"])

    def test_cam_variant_still_parses(self):
        p = W.parse(T1_CAM)
        self.assertTrue(p["ok"])
        self.assertEqual(p["cam"], 1)
        self.assertIsNone(p["flags"])

    def test_template3_flags_present(self):
        p = W.parse(T3_UNDER)
        self.assertTrue(p["ok"])
        self.assertEqual(p["net"], 6.2)
        self.assertEqual(p["flags"], {"under": 1, "over": 0, "ok": 0})

    def test_template3_all_zero_is_parsed_not_judged(self):
        p = W.parse(T3_ZERO)
        self.assertEqual(p["flags"], {"under": 0, "over": 0, "ok": 0})

    def test_flags_without_trailing_line_break(self):
        self.assertFalse(T3_OK.endswith("\n"))
        self.assertEqual(W.parse(T3_OK)["flags"], {"under": 0, "over": 0, "ok": 1})

    def test_flags_line_with_lf_only_and_extra_spaces(self):
        p = W.parse("50.0 lb N\nUNDER:  0   OVER: 1  OK:0")
        self.assertEqual(p["flags"], {"under": 0, "over": 1, "ok": 0})

    def test_flags_on_the_net_line(self):
        # Malaki's how-to doc showed them there; accepted anywhere.
        p = W.parse("      66.0 lb \r\n      16.0 lb T \r\n      50.0 lb N UNDER: 0 OVER: 0 OK: 1")
        self.assertTrue(p["ok"])
        self.assertEqual(p["netText"], "50.0")
        self.assertEqual(p["flags"], {"under": 0, "over": 0, "ok": 1})
        self.assertEqual(p["flagsState"], "read")

    def _assertUnreadable(self, message):
        p = W.parse(message)
        self.assertTrue(p["ok"], "a flags problem must never refuse the weighment")
        self.assertIsNone(p["flags"])
        self.assertEqual(p["flagsState"], "unreadable")

    def test_value_other_than_0_or_1_is_unreadable(self):
        self._assertUnreadable("50.0 lb N\r\nUNDER: 0 OVER: 0 OK: 2")
        self._assertUnreadable("50.0 lb N\r\nUNDER: 0 OVER: 0 OK: 01")

    def test_more_than_one_flag_set_is_unreadable(self):
        self._assertUnreadable("50.0 lb N\r\nUNDER: 1 OVER: 0 OK: 1")

    def test_partial_flags_line_is_unreadable(self):
        self._assertUnreadable("50.0 lb N\r\nUNDER: OVER: 0")
        self._assertUnreadable("50.0 lb N\r\nUNDER: 1")

    def test_absent_flags_state(self):
        self.assertEqual(W.parse(T1)["flagsState"], "absent")

    def test_still_exactly_one_net_line(self):
        self.assertFalse(W.parse(T3_OK + "\r\n" + T3_OK)["ok"])
        self.assertFalse(W.parse("UNDER: 0 OVER: 0 OK: 1")["ok"])

    def test_template3_record_matches_the_real_print(self):
        # The 1:44 PM print on 2026-10-19 was 74 bytes: 52.9 / 3.0 T / 49.9 N, OK.
        rec = W.template3Record(52.9, 3.0, 49.9, 0, 0, 1)
        self.assertEqual(len(rec), 74)
        self.assertEqual(rec, "      52.9 lb \r\n       3.0 lb T \r\n      49.9 lb N \r\nUNDER: 0 OVER: 0 OK: 1")
        p = W.parse(rec)
        self.assertEqual((p["net"], p["flags"]), (49.9, {"under": 0, "over": 0, "ok": 1}))

    def test_two_flags_lines_are_unreadable_not_refused(self):
        self._assertUnreadable("50.0 lb N\r\nUNDER: 0 OVER: 0 OK: 1\r\nUNDER: 1 OVER: 0 OK: 0")


class HandleMessageTests(unittest.TestCase):

    def _run(self, message, row, **kw):
        rec = Recorder(judgeRow=row, **kw)
        rec.install(W)
        result = W.handleMessage("[MPP]PlcDevices/MPP_Scale", 106, message)
        return rec, result

    def test_flags_absent_closes_and_logs_none(self):
        rec, result = self._run(T1, _row("Ok"))
        self.assertEqual(result["Status"], 1)
        self.assertIsNone(rec.judgeCalls[0]["scaleFlags"])
        self.assertEqual(len(rec.logs), 1)
        body = json.loads(rec.logs[0]["requestPayload"])
        self.assertIsNone(body["flags"])
        self.assertEqual(body["flagsState"], "absent")
        self.assertIsNone(body["scaleVerdict"])
        self.assertIsNone(body["agree"])

    def test_flags_present_and_agreeing(self):
        rec, result = self._run(T3_OK, _row("Ok", scale="Ok", agree=True))
        self.assertEqual(result["Status"], 1)
        self.assertEqual(rec.judgeCalls[0]["scaleFlags"], {"under": 0, "over": 0, "ok": 1})
        self.assertEqual([l["description"] for l in rec.logs], ["ByWeight tray close"])
        body = json.loads(rec.logs[0]["requestPayload"])
        self.assertEqual(body["flags"], {"under": 0, "over": 0, "ok": 1})
        self.assertEqual(body["scaleVerdict"], "Ok")
        self.assertIs(body["agree"], True)
        self.assertEqual(rec.alarms, [])

    def test_mismatch_on_an_ok_tray_still_closes_and_warns(self):
        rec, result = self._run(T3_UNDER, _row("Ok", scale="Under", agree=False,
                                               flagsMessage="scale Under, MES Ok"))
        self.assertEqual(result["Status"], 1)
        self.assertEqual(rec.closes, ["ByWeight"])
        self.assertEqual([l["description"] for l in rec.logs],
                         ["Scale flags warning", "ByWeight tray close"])
        warn = rec.logs[0]
        self.assertEqual(warn["errorCondition"], "ScaleFlagsMismatch")
        self.assertEqual(warn["errorDescription"], "scale Under, MES Ok")
        self.assertTrue(warn["ok"])
        self.assertEqual(rec.alarms, [], "a flags mismatch raises no operator toast")

    def test_mismatch_on_a_refused_tray_still_refuses_and_warns(self):
        rec, result = self._run(T3_OK, _row("Over", scale="Ok", agree=False,
                                            flagsMessage="scale Ok, MES Over"))
        self.assertEqual(result["Status"], 0)
        self.assertEqual(rec.closes, [])
        self.assertEqual([l["description"] for l in rec.logs],
                         ["Scale flags warning", "Tray not closed"])
        body = json.loads(rec.logs[1]["requestPayload"])
        self.assertEqual(body["flags"], {"under": 0, "over": 0, "ok": 1})
        self.assertEqual(body["scaleVerdict"], "Ok")
        self.assertIs(body["agree"], False)
        # The only toast is the MES refusal itself.
        self.assertEqual(len(rec.alarms), 1)
        self.assertEqual(rec.alarms[0]["level"], "warning")

    def test_all_zero_is_no_target_not_a_mismatch(self):
        rec, result = self._run(T3_ZERO, _row("Ok", scale="NoTarget", agree=None,
                                              flagsMessage="no active target"))
        self.assertEqual(result["Status"], 1)
        self.assertEqual(rec.judgeCalls[0]["scaleFlags"], {"under": 0, "over": 0, "ok": 0})
        self.assertEqual(rec.logs[0]["errorCondition"], "ScaleFlagsNoTarget")
        self.assertEqual(rec.alarms, [])

    def test_unreadable_flags_still_close_and_say_so(self):
        rec, result = self._run(
            "      66.0 lb \r\n      16.0 lb T \r\n      50.0 lb N \r\nUNDER: 1 OVER: 1 OK: 0",
            _row("Ok"))
        self.assertEqual(result["Status"], 1)
        self.assertIsNone(rec.judgeCalls[0]["scaleFlags"])
        body = json.loads(rec.logs[0]["requestPayload"])
        self.assertIsNone(body["flags"])
        self.assertEqual(body["flagsState"], "unreadable")

    def test_flags_on_a_refusal_before_judging(self):
        rec, result = self._run(T3_OK.replace(" lb", " kg"), _row("Ok"))
        self.assertEqual(result["Status"], 0)
        self.assertEqual(rec.judgeCalls, [])
        self.assertEqual(json.loads(rec.logs[0]["requestPayload"])["flags"],
                         {"under": 0, "over": 0, "ok": 1})

    # ---- Task 2 (scale station spec §4): JSON payload, context, broadcast ----

    def test_payload_is_json_v1(self):
        rec, result = self._run(T3_OK, _row("Ok", scale="Ok", agree=True))
        body = json.loads(rec.logs[0]["requestPayload"])
        self.assertEqual(body["v"], 1)
        self.assertEqual(body["net"], 50.0)
        self.assertEqual(body["uom"], "lb")
        self.assertEqual(body["verdict"], "Ok")
        self.assertEqual(body["low"], 48.0)
        self.assertEqual(body["high"], 52.0)
        self.assertEqual(body["flags"], {"under": 0, "over": 0, "ok": 1})
        self.assertIs(body["agree"], True)
        self.assertEqual(json.loads(rec.logs[0]["responsePayload"])["Status"], 1)

    def test_refusal_before_judging_omits_verdict(self):
        rec, result = self._run(T3_OK.replace(" lb", " kg"), _row("Ok"))
        body = json.loads(rec.logs[0]["requestPayload"])
        self.assertNotIn("verdict", body)
        self.assertEqual(body["uom"], "kg")
        self.assertIsNone(rec.logs[0].get("itemId"))
        self.assertEqual(rec.logs[0]["locationId"], 106)

    def test_context_on_close(self):
        rec, result = self._run(T3_OK, _row("Ok", scale="Ok", agree=True),
                                closeResult={"Status": 1, "ContainerId": 9, "FinishedGoodLotId": 77})
        log = rec.logs[-1]
        self.assertEqual((log["locationId"], log["itemId"], log["lotId"]), (106, 110, 77))

    def test_context_on_refusal(self):
        rec, result = self._run(T3_UNDER, _row("Under", scale="Under", agree=True))
        log = rec.logs[-1]
        self.assertEqual((log["locationId"], log["itemId"]), (106, 110))
        self.assertIsNone(log.get("lotId"))

    def test_press_broadcast_every_outcome(self):
        cases = [
            (T3_OK, _row("Ok"), None),                                  # close
            (T3_UNDER, _row("Under"), None),                            # refusal
            ("no weight here", _row("Ok"), None),                       # unreadable
            (T3_OK, _row("Ok"), {"Status": 0, "Message": "boom"}),      # failed close
        ]
        for message, row, closeResult in cases:
            rec, result = self._run(message, row, closeResult=closeResult)
            self.assertEqual(rec.broadcasts, [("scalePressRecorded", {"terminalLocationId": 106})],
                             "exactly one broadcast for %r" % message[:20])

    def test_flags_warning_row_carries_context(self):
        rec, result = self._run(T3_UNDER, _row("Ok", scale="Under", agree=False,
                                               flagsMessage="scale Under, MES Ok"))
        warn = rec.logs[0]
        self.assertEqual(warn["description"], "Scale flags warning")
        self.assertEqual((warn["locationId"], warn["itemId"]), (106, 110))


ASSEMBLY = os.path.join(ROOT, "ignition", "projects", "Core", "ignition",
                        "script-python", "BlueRidge", "Workorder", "Assembly", "code.py")


def _loadAssembly(runningPart, calls):
    """Assembly/code.py with the BlueRidge entities resolvePlcCloseContext
       touches stubbed. `calls` records every ScaleStation lookup."""
    if "system.perspective" not in sys.modules:
        mod = types.ModuleType("system.perspective")
        sys.modules["system.perspective"] = mod
        sys.modules["system"].perspective = mod
    a = types.ModuleType("Assembly")
    with open(ASSEMBLY) as f:
        exec(compile(f.read(), ASSEMBLY, "exec"), a.__dict__)
    BR = types.SimpleNamespace()
    BR.Common = types.SimpleNamespace(
        Util=types.SimpleNamespace(extractQualifiedValues=lambda v: v, log=lambda *x, **k: None))
    BR.Location = types.SimpleNamespace(Terminal=types.SimpleNamespace(
        listAll=lambda: [{"Id": 106, "ZoneId": 104}],
        findById=lambda rows, tid: rows[0]))
    BR.Workorder = types.SimpleNamespace(ScaleStation=types.SimpleNamespace(
        getRunningPartOrEmpty=lambda tid, _token=None: calls.append(tid) or dict(runningPart)))
    BR.Parts = types.SimpleNamespace(ContainerConfig=types.SimpleNamespace(
        getByItemAndMethod=lambda item, method: {"PartsPerTray": 24}))
    a.BlueRidge = BR
    a.getStationContainerRows = lambda cell, tid, method: []
    a._recommendedWithPackout = lambda cell, method: 555
    return a


class CloseContextTests(unittest.TestCase):
    """Task 5: a ByWeight close takes its part from the same SQL rule the
       screen shows (Workorder.ScaleStation_GetRunningPart)."""

    def test_byweight_close_uses_running_part(self):
        calls = []
        a = _loadAssembly({"ItemId": 222, "Source": "Override", "PartsPerTray": 6,
                           "OpenContainerId": 9001, "Message": ""}, calls)
        ctx = a.resolvePlcCloseContext(106, "ByWeight")
        self.assertEqual(calls, [106])
        self.assertEqual(ctx, {"cellLocationId": 104, "finishedGoodItemId": 222,
                               "pieceCount": 6, "containerId": 9001})

    def test_byweight_none_is_error(self):
        a = _loadAssembly({"ItemId": None, "Source": "None", "PartsPerTray": 0,
                           "OpenContainerId": None, "Message": "No finished good can run."}, [])
        self.assertEqual(a.resolvePlcCloseContext(106, "ByWeight"),
                         {"error": "No finished good can run."})

    def test_byvision_path_unchanged(self):
        calls = []
        a = _loadAssembly({"ItemId": 222, "Source": "Default", "PartsPerTray": 6,
                           "OpenContainerId": None, "Message": ""}, calls)
        ctx = a.resolvePlcCloseContext(106, "ByVision")
        self.assertEqual(calls, [], "ByVision must not consult the scale station rule")
        self.assertEqual(ctx["finishedGoodItemId"], 555)
        self.assertEqual(ctx["pieceCount"], 24)


STATION = os.path.join(ROOT, "ignition", "projects", "Core", "ignition",
                       "script-python", "BlueRidge", "Workorder", "ScaleStation", "code.py")


def _loadStation(runningPart=None, pressRows=None, boxRows=None, parts=None, devices=None):
    """ScaleStation/code.py with its SQL reads stubbed: the presentation
       helpers the scale station views bind to are tested here."""
    s = types.ModuleType("ScaleStation")
    with open(STATION) as f:
        exec(compile(f.read(), STATION, "exec"), s.__dict__)
    BR = types.SimpleNamespace()
    BR.Common = types.SimpleNamespace(Util=types.SimpleNamespace(extractQualifiedValues=lambda v: v))
    BR.Location = types.SimpleNamespace(TerminalPlcDevice=types.SimpleNamespace(
        getByTerminal=lambda tid: list(devices or [])))
    s.BlueRidge = BR
    s.getRunningPartOrEmpty = lambda tid, _token=None: dict(s._RUNNING_PART_SHAPE, **(runningPart or {}))
    s.getPressLog = lambda tid, top=20, _token=None: list(pressRows or [])[:top]
    s.getRecentBoxes = lambda tid, top=5, _token=None: list(boxRows or [])[:top]
    s.listEligibleParts = lambda tid, _token=None: list(parts or [])
    s._fmtTime = lambda d: "%s" % d
    return s


CLOSE_ROW = {"LoggedAtEt": "9:41:52 AM", "Net": 18.31, "Uom": "lb", "Verdict": "Ok",
             "Low": 17.75, "High": 18.75, "ScaleVerdict": "Ok", "FlagsAgree": True,
             "Outcome": "Closed", "Detail": None, "LotName": "MESL1", "TrayPosition": 7,
             "TraysPerContainer": 16, "LabelStatus": None}
UNDER_ROW = {"LoggedAtEt": "9:35:41 AM", "Net": 15.3, "Uom": "lb", "Verdict": "Under",
             "Low": 17.75, "High": 18.75, "ScaleVerdict": "Under", "FlagsAgree": False,
             "Outcome": "Refused", "Detail": "Tray is UNDER weight", "LotName": None,
             "TrayPosition": None, "TraysPerContainer": None, "LabelStatus": None}


class StationHelperTests(unittest.TestCase):
    """Task 7: presentation helpers behind the scale station views."""

    def test_tray_cells_mark_closed_next_and_todo(self):
        s = _loadStation(runningPart={"TraysPerContainer": 4, "OpenContainerId": 9, "OpenTraysClosed": 2})
        self.assertEqual([c["state"] for c in s.trayCells(106)], ["closed", "closed", "next", "todo"])
        self.assertEqual([c["n"] for c in s.trayCells(106)], [1, 2, 3, 4])

    def test_tray_cells_with_no_open_box_start_at_one(self):
        s = _loadStation(runningPart={"TraysPerContainer": 3, "OpenContainerId": None, "OpenTraysClosed": 0})
        self.assertEqual([c["state"] for c in s.trayCells(106)], ["next", "todo", "todo"])

    def test_press_rows_closed_and_refused(self):
        s = _loadStation(pressRows=[CLOSE_ROW, UNDER_ROW])
        rows = s.pressLogInstances(106, 10)
        self.assertEqual(rows[0]["verdict"], "OK")
        self.assertEqual(rows[0]["outcome"], "Tray 7 of 16 closed, LOT MESL1")
        self.assertEqual(rows[0]["scale"], "OK, agrees")
        self.assertEqual(rows[1]["verdict"], "UNDER")
        self.assertEqual(rows[1]["outcome"], "Not closed: Tray is UNDER weight")
        self.assertEqual(rows[1]["scale"], "UNDER, differs")
        self.assertNotEqual(rows[0]["verdictClass"], rows[1]["verdictClass"])

    def test_box_completing_tray_says_so(self):
        row = dict(CLOSE_ROW, TrayPosition=16, LabelStatus="Sent")
        s = _loadStation(pressRows=[row])
        self.assertEqual(s.pressLogInstances(106, 1)[0]["outcome"],
                         "Tray 16 of 16 closed, LOT MESL1, box complete, label sent")

    def test_last_press_or_empty_has_shape_when_none(self):
        s = _loadStation(pressRows=[])
        last = s.lastPressOrEmpty(106)
        self.assertEqual(last["hasPress"], False)
        for k in ("time", "net", "verdict", "verdictClass", "outcome", "scale", "window"):
            self.assertIn(k, last)

    def test_last_press_window_text(self):
        s = _loadStation(pressRows=[CLOSE_ROW])
        last = s.lastPressOrEmpty(106)
        self.assertEqual((last["hasPress"], last["net"], last["window"]),
                         (True, "18.31 lb", "17.75 - 18.75 lb"))

    def test_box_instances(self):
        s = _loadStation(boxRows=[{"ContainerId": 5, "CompletedAtEt": "8:50 AM", "Pieces": 96, "Trays": 16,
                                   "LotName": "MESL9", "AimShipperId": "AIM-1", "LabelStatus": "Failed"}])
        b = s.boxInstances(106, 5)[0]
        self.assertEqual((b["containerId"], b["title"], b["labelStatus"]),
                         (5, "Box #5 - 96 pcs, 16 trays", "Label failed"))

    def test_eligible_part_options(self):
        s = _loadStation(parts=[{"ItemId": 7, "PartNumber": "19321-66V -A000", "Description": "66V Thermo Case",
                                 "TraysCovered": 8}])
        self.assertEqual(s.eligiblePartOptions(106),
                         [{"label": "19321-66V -A000  66V Thermo Case  (parts for 8 trays)", "value": 7}])

    def test_apply_part_choice_sets_notifies_broadcasts_and_closes(self):
        s = _loadStation()
        seen = {"set": [], "notify": [], "msg": [], "close": []}
        s.setRunningPart = lambda tid, item, appUserId=None: seen["set"].append((tid, item, appUserId)) or {"Status": 1, "Message": "ok"}
        s.BlueRidge.Common.Session = types.SimpleNamespace(currentAppUserId=lambda sess: 22)
        s.BlueRidge.Common.Ui = types.SimpleNamespace(notifyResult=lambda r, title, *a, **k: seen["notify"].append(title))
        s.system = types.SimpleNamespace(perspective=types.SimpleNamespace(
            sendMessage=lambda t, payload=None, scope=None: seen["msg"].append((t, payload, scope)),
            closePopup=lambda id=None: seen["close"].append(id)))
        s.applyPartChoice(object(), 106, 7)
        self.assertEqual(seen["set"], [(106, 7, 22)])
        self.assertEqual(seen["msg"], [("scaleRunningPartChanged", {"terminalLocationId": 106}, "page")])
        self.assertEqual(seen["close"], ["mpp-scale-part-picker"])

    def test_apply_part_choice_refused_keeps_popup_open(self):
        s = _loadStation()
        closed = []
        s.setRunningPart = lambda tid, item, appUserId=None: {"Status": 0, "Message": "no"}
        s.BlueRidge.Common.Session = types.SimpleNamespace(currentAppUserId=lambda sess: 22)
        s.BlueRidge.Common.Ui = types.SimpleNamespace(notifyResult=lambda *a, **k: None)
        s.system = types.SimpleNamespace(perspective=types.SimpleNamespace(
            sendMessage=lambda *a, **k: None, closePopup=lambda id=None: closed.append(id)))
        s.applyPartChoice(object(), 106, None)
        self.assertEqual(closed, [])

    # ---- refresh rule (one refresh per event, only for this station) ----

    def test_refresh_on_own_press_and_part_change(self):
        s = _loadStation()
        self.assertTrue(s.shouldRefresh("scalePressRecorded", {"terminalLocationId": 106}, "106", 104))
        self.assertTrue(s.shouldRefresh("scaleRunningPartChanged", {"terminalLocationId": 106}, 106, 104))

    def test_no_refresh_for_another_terminals_press(self):
        s = _loadStation()
        self.assertFalse(s.shouldRefresh("scalePressRecorded", {"terminalLocationId": 107}, 106, 104))

    def test_inventory_change_from_own_close_is_not_a_second_refresh(self):
        s = _loadStation()
        self.assertFalse(s.shouldRefresh("inventoryChanged", {"cellLocationId": 104, "terminalLocationId": 106}, 106, 104))

    def test_inventory_change_at_this_line_by_another_station_refreshes(self):
        s = _loadStation()
        self.assertTrue(s.shouldRefresh("inventoryChanged", {"cellLocationId": 104, "terminalLocationId": 110}, 106, 104))

    def test_inventory_change_at_another_line_does_not(self):
        s = _loadStation()
        self.assertFalse(s.shouldRefresh("inventoryChanged", {"cellLocationId": 999, "terminalLocationId": 110}, 106, 104))

    def test_local_stock_move_on_this_page_refreshes(self):
        # InventoryManager's own page-scoped message carries no cell or terminal.
        s = _loadStation()
        self.assertTrue(s.shouldRefresh("inventoryChanged", {}, 106, 104))
        self.assertTrue(s.shouldRefresh("inventoryChanged", None, 106, 104))

    def test_tray_cells_from_a_running_part_dict(self):
        s = _loadStation()
        self.assertEqual([c["state"] for c in s.trayCellsFor(3, 1, 5)], ["closed", "next", "todo"])
        self.assertEqual([c["state"] for c in s.trayCellsFor(2, 0, None)], ["next", "todo"])

    def test_scale_status_text(self):
        s = _loadStation(devices=[{"DeviceTypeCode": "ScaleStationEPrint", "UdtInstancePath": "[MPP]PlcDevices/Scale"}])
        reads = []
        s.system = types.SimpleNamespace(tag=types.SimpleNamespace(
            readBlocking=lambda paths: reads.append(paths) or [types.SimpleNamespace(value="2:54:28 PM")]))
        self.assertEqual(s.scaleStatusText(106), "Scale last message 2:54:28 PM")
        self.assertEqual(reads, [["[MPP]PlcDevices/Scale/LastReceiveTime"]])
        self.assertEqual(_loadStation(devices=[]).scaleStatusText(106), "No scale is mapped to this terminal")

    def test_scale_status_text_never(self):
        s = _loadStation(devices=[{"DeviceTypeCode": "ScaleStationEPrint", "UdtInstancePath": "[MPP]PlcDevices/Scale"}])
        s.system = types.SimpleNamespace(tag=types.SimpleNamespace(
            readBlocking=lambda paths: [types.SimpleNamespace(value=None)]))
        self.assertEqual(s.scaleStatusText(106), "Scale last message: never")

    def test_scale_instance_path_picks_the_eprint_device(self):
        s = _loadStation(devices=[{"DeviceTypeCode": "TrayInspectionStation", "UdtInstancePath": "[MPP]PlcDevices/Cam"},
                                  {"DeviceTypeCode": "ScaleStationEPrint", "UdtInstancePath": "[MPP]PlcDevices/Scale"}])
        self.assertEqual(s.scaleInstancePath(106), "[MPP]PlcDevices/Scale")
        self.assertEqual(_loadStation(devices=[]).scaleInstancePath(106), "")


if __name__ == "__main__":
    if not FIXTURES_VERIFIED:
        sys.stderr.write("NOTE: Template 3 fixtures are a reconstruction, not "
                         "captured bytes (FIXTURES_VERIFIED = False).\n")
    unittest.main()
