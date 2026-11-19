"""BlueRidge.Workorder.ScaleDigiWatcher - assembly checkweigh scales read through
   a Digi One SP on the IND570's serial port.

   Spec: docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md
   Findings: notes/2026-11-19_digi-one-sp-scale-capture.md
   UDT:  ignition/tags/udt/ScaleStationEPrint.json (reused: the same three TCP
         driver members). The PlcDeviceType ScaleStationDigi, not the UDT,
         routes a device here (PlcWatcher.dispatchMessage).

   Sits BESIDE ScaleEPrintWatcher, which is legacy and is not edited. Every
   production scale goes through a Digi box (Jacques, 2026-11-19).

   SHAPE. The head runs its compiled TaskExpert program, which sends ONE record
   per GOOD press on the serial port and nothing for a bad weight (it turns the
   stack light red instead):

        (NET)15.5<UOM>LB<TWM>1<Part>TEST3   CR LF LF

   The TCP driver is Character Based on CR, so each message carries the
   previous record's two LFs at its front; the Digi breaks the record into
   1-4 byte packets, which the driver reassembles up to the CR. The data is in
   MessageBytes -- the Message string tag reads blank.

   WHO DECIDES (Jacques, 2026-11-19).
     - The scale decides GOOD: TWM=1 closes the tray. The MES still judges the
       net weight against ContainerConfig and logs a warning when it disagrees;
       it never blocks.
     - The scale decides the PART: <Part> is looked up as an MES PartNumber.
       A different part than the running one switches the station's running
       part (Location.Terminal_SetScaleRunningPart, audited), which refuses
       while another part's box is open -- a box never mixes parts.
     - A code that matches no part: closes as the running part when that part
       is already settled (an open box, or an operator override); otherwise
       the press is HELD (Workorder.ScalePendingPress) and the operator picks
       the part on the scale station screen, which closes the tray.

   Every new InterfaceLog warning's ErrorCondition starts with 'ScaleFlags' so
   Workorder.ScaleStation_GetPressLog keeps it out of the press log.
"""

import java.lang
import re

import system.opc
import system.tag
import system.util


EXPECTED_UOM = "lb"
SOURCE_SCALE = "Scale"
SOURCE_RUNNING = "Running"
SOURCE_PICKED = "Picked"

# (NET)<number><UOM><letters><TWM><digit><Part><rest of the line>
_RECORD = re.compile(r"^\(NET\)\s*(-?\d+(?:\.\d+)?)\s*<UOM>\s*([A-Za-z]+)\s*"
                     r"<TWM>\s*(\d)\s*<Part>([^\r\n]*)$")
_MARK = "(NET)"


def decodeBytes(raw):
    """MessageBytes as text. The driver hands back a Java byte[] (signed
       values in Jython) or a list of ints; each is one ASCII byte."""
    if raw is None:
        return None
    return "".join([chr(int(b) & 0xFF) for b in raw])


def parse(message):
    """One Digi record.

       Returns {"ok": True, "net": float, "netText": str, "uom": str,
                "twm": int, "part": str}
            or {"ok": False, "reason": str}.

       Leading / trailing CR, LF and whitespace are the driver's framing and
       are stripped. Exactly ONE record is required: two would be two presses
       run together, and acting on either would be a guess. TWM is parsed, not
       judged -- the watcher decides what a 0 means."""
    text = ("" if message is None else "%s" % message).strip()
    count = text.count(_MARK)
    if count == 0:
        return {"ok": False, "reason": "The scale sent no weighment record."}
    if count > 1:
        return {"ok": False,
                "reason": "The scale sent %d weighment records at once; expected one." % count}
    m = _RECORD.match(text)
    if not m:
        return {"ok": False,
                "reason": "The scale's record could not be read: %s" % text[:80]}
    netText, uom, twm, part = m.groups()
    return {"ok": True, "net": float(netText), "netText": netText, "uom": uom,
            "twm": int(twm), "part": part.strip()}


def digiRecord(net, part, twm=1, uom="LB"):
    """The record exactly as the TCP driver delivers it for one press (the
       previous record's LFs in front, CR at the end), for the dev simulator
       (BlueRidge.Sim.fireScaleDigi)."""
    return "\n\n(NET)%.1f<UOM>%s<TWM>%d<Part>%s\r" % (float(net), uom, int(twm), part)
