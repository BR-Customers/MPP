"""BlueRidge.Workorder.ScaleWatcher - assembly scale handshake (OmniServer scales).

   Rising edge on NET_DataReady (spec Sec 5 archetype):
     read NET_NetWeightValue / NET_NetWeightUOM / NET_TargetWeightMetFlag ->
     clear NET_DataReady (ack) -> log the weigh to Audit.InterfaceLog -> if the
     target-weight-met flag is set, the scale is COUPLED to container completion.

   Two commissioning fill-ins (deliberately not faked -- spec Sec 5.2):
   (1) There is no raw-weight persistence proc; the weigh is captured in the
       InterfaceLog payload. Whether MPP wants the net weight retained as a
       ProductionEvent / QualitySample is an open decision.
   (2) On 5G0 the scale MetFlag couples to the MIP line's container completion
       (legacy hardcoded count=60 -> ContainerConfig closure). That cross-device
       coupling is line-specific; _completeCoupledContainer is the wired hook,
       returning None (skip) until the scale<->cell coupling is supplied.

   Target-weight change (MES -> scale: write TRG_* zero-padded + pulse
   TRG_SendMessage) is initiated from the Sim Panel / operator flow, not this
   read-edge watcher. HMI writes gated (spec Sec 5.1).
"""

import BlueRidge.Common.Util
import BlueRidge.Workorder.PlcWatcher

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
        cid = _completeCoupledContainer(terminalLocationId, device)
        if cid is None:
            BlueRidge.Common.Util.log(
                "scale metFlag on %s: container-completion coupling is a commissioning "
                "fill-in (skipped)" % instancePath, level="debug")


def _completeCoupledContainer(terminalLocationId, device):
    """COMMISSIONING: resolve + complete the container the scale is coupled to
       (5G0 scale -> MIP cell). Returns the completed ContainerId, or None to skip
       until the scale<->cell coupling is supplied. Left as a hook so the coupling
       is a data/config change, not a code change -- and never a faked completion."""
    return None
