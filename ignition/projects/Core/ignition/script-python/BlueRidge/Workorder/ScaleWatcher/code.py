"""BlueRidge.Workorder.ScaleWatcher - assembly scale handshake (OmniServer scales).

   Rising edge on NET_DataReady (spec Sec 5 archetype):
     read NET_NetWeightValue / NET_NetWeightUOM / NET_TargetWeightMetFlag ->
     clear NET_DataReady (ack) -> log the weigh to Audit.InterfaceLog -> if the
     target-weight-met flag is set, the scale is COUPLED to container completion.

   On target-weight-met the scale closes the tray for the terminal's cell:
   _completeCoupledContainer -> Assembly.plcCompleteTray("ByWeight"), the same
   Assembly_CompleteTray path the operator uses. The scale greenlit the DEFAULT
   quantity, so the piece count is the finished good's configured ByWeight
   PartsPerTray (the weight validated the count).

   One commissioning fill-in remains (deliberately not faked -- spec Sec 5.2):
   there is no raw-weight persistence proc; the weigh is captured in the
   InterfaceLog payload. Whether MPP wants the net weight retained as a
   ProductionEvent / QualitySample is an open decision.

   Target-weight change (MES -> scale: write TRG_* zero-padded + pulse
   TRG_SendMessage) is initiated from the Sim Panel / operator flow, not this
   read-edge watcher. HMI writes gated (spec Sec 5.1).
"""

import BlueRidge.Common.Util
import BlueRidge.Workorder.PlcWatcher
import BlueRidge.Workorder.Assembly

_TRIGGERS = ("NET_DataReady",)


def handleEdge(instancePath, terminalLocationId, member):
    if member not in _TRIGGERS:
        return
    W = BlueRidge.Workorder.PlcWatcher
    device = instancePath.rsplit("/", 1)[-1]

    vals = W.readMembers(instancePath,
                         ["NET_NetWeightValue", "NET_NetWeightUOM", "NET_TargetWeightMetFlag"])
    weight = vals.get("NET_NetWeightValue")
    uom = vals.get("NET_NetWeightUOM")
    metFlag = bool(vals.get("NET_TargetWeightMetFlag"))

    # Ack the consumed trigger.
    W.writeMember(instancePath, "NET_DataReady", False)

    W.logInterface(device, "Scale weigh",
                   requestPayload="weight=%s uom=%s metFlag=%s" % (weight, uom, metFlag),
                   ok=True)

    if metFlag:
        _completeCoupledContainer(instancePath, terminalLocationId, device)


def _completeCoupledContainer(instancePath, terminalLocationId, device):
    """Scale target-weight-met -> record the tray close for the terminal's cell:
       mint the FG LOT + consume BOM via the shared PLC close (the SAME
       Assembly_CompleteTray path the operator ByCount button uses). The scale
       greenlit the DEFAULT quantity, so piece count = the finished good's
       configured ByWeight PartsPerTray; the container auto-completes (AIM + label)
       when full. Returns the ContainerId on success, else None (logged + HMI
       alarm) -- never a faked completion."""
    W = BlueRidge.Workorder.PlcWatcher
    result = BlueRidge.Workorder.Assembly.plcCompleteTray(terminalLocationId, "ByWeight")
    ok = bool(result and result.get("Status"))
    W.logInterface(device, "ByWeight tray close",
                   requestPayload="terminal=%s" % terminalLocationId,
                   responsePayload=str(result), ok=ok,
                   errorDescription=None if ok else (result or {}).get("Message"))
    if not ok:
        W.writeDisplay(instancePath, {"MESAlarmType": 1,
                                      "MESAlarmText": (result or {}).get("Message") or "Tray close failed"})
        return None
    return result.get("ContainerId")
