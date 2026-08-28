# =============================================================================
# generate_tags.py  --  single source of truth for the PLC UDT tag artifacts
# =============================================================================
# Spec: docs/superpowers/specs/2026-07-10-plc-udt-terminal-mapping-design.md
# Plan: docs/superpowers/plans/2026-07-13-plc-integration-plan2-ignition-udts-sim.md
#
# Emits, from the ONE member catalog + the device manifest, so real UDTs and the
# sim device can never drift (spec Sec 3.1 / Sec 8):
#   ignition/tags/udt/<Type>.json          -- 4 UDT definitions
#   ignition/tags/instances/PlcDevices.json -- 22 UDT instances (a Folder)
#   ignition/tags/sim/MPP_Sim_program.csv   -- Programmable Device Simulator program
#
# Run:  python ignition/tags/generate_tags.py   (from the repo root)
#
# ---- ADDRESSING SCHEME (commissioning note) ---------------------------------
# The OPC member item path is  ns=1;s=[{Device}]{BasePath}<Member>  -- the member
# name is appended DIRECTLY to {BasePath} (exactly the reference SampleUDT.json
# pattern `[{Device}]{BasePath}0`).  The address separator therefore lives in
# {BasePath}, swapped per instance/environment:
#   * dev/sim :  BasePath = "<device>/"   (trailing slash -> matches the
#                Programmable Device Simulator browse paths "<device>/<member>")
#   * prod    :  BasePath = the real device base incl. its trailing separator,
#                e.g. "5G0_A1.5G0_A1."  (TopServer/Mitsubishi dotted path).
# This keeps ONE definition working for sim and every real device by changing
# only the {BasePath} parameter value -- nothing in the definition.  Spec Sec 3.4
# writes an explicit ".<Member>" and Sec 7.1 a "/" browse path; those disagree,
# and Sec 6.1 calls the exact namespace string "a trivial commissioning fill-in".
# We resolve it here to the sample-faithful, self-consistent form above.
# =============================================================================

import csv
import json
import os

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MANIFEST = os.path.join(REPO, "reference", "legacy_mes_extract", "emmd_automation",
                        "integration_manifest.csv")
TAGS_DIR = os.path.join(REPO, "ignition", "tags")

OPC_SERVER_DEFAULT = "Ignition OPC UA Server"
SIM_DEVICE = "MPP_Sim"

# ---- datatype maps ----------------------------------------------------------
# kind -> Ignition tag-JSON dataType
TAG_DTYPE = {"bool": "Boolean", "int": "Int4", "real": "Float8", "str": "String"}
# kind -> Programmable Device Simulator CSV "Data Type"
SIM_DTYPE = {"bool": "Boolean", "int": "Int32", "real": "Double", "str": "String"}
# kind -> writeable literal default (a plain literal = a writeable sim tag)
SIM_LITERAL = {"bool": "false", "int": "0", "real": "0.0", "str": ""}

# ---- member catalog (spec Sec 3.3) ------------------------------------------
# Every member is DECLARED in the UDT (cheap; keeps the sim/real contract
# complete). The watcher (Plan 3) decides read vs write; display members are
# gated by WriteDisplayEnabled (spec Sec 5.1 / 5.3).
SERIALIZED = [
    ("DataReady", "bool"), ("TransInProc", "bool"), ("PartSN", "str"),
    ("PartComplete", "bool"), ("HardwareInterlockEnforced", "bool"),
    ("PartValid", "bool"), ("ContainerCount", "int"),
    ("ContainerCountRequest", "bool"), ("PartType", "int"),
    ("MESAlarmType", "int"), ("MESAlarmText", "str"),
]
NONSERIALIZED = [
    ("DataReady", "bool"), ("TransInProc", "bool"), ("PartValid", "bool"),
    ("PartType", "int"), ("MESAlarmType", "int"), ("MESAlarmText", "str"),
]
TRAY = (
    [("TrayLocked", "bool"), ("InspectionComplete", "bool"),
     ("PartNumber", "int"), ("VisionPartNumber", "int")]
    + [("PartDisposition%02d" % i, "bool") for i in range(1, 19)]
    + [("OkToContinue", "bool"), ("ContainerName", "str")]
)

def opc_member(name, kind, address=None):
    """One OPC AtomicTag member -- opcServer + opcItemPath are parameter binds.

    address=None  -> the member NAME is the address, appended directly to
                     {BasePath} (the original scheme; separator lives in
                     BasePath -- MIP + tray types).
    address given -> the tag name and the OPC address are decoupled, so a
                     UDT can present friendly names over raw register
                     addresses (the IND570 scale over Modbus TCP).
    """
    return {
        "name": name,
        "dataType": TAG_DTYPE[kind],
        "valueSource": "opc",
        "opcServer": {"bindType": "parameter", "binding": "{OpcServer}"},
        "opcItemPath": {"bindType": "parameter",
                        "binding": "ns=1;s=[{Device}]{BasePath}" + (address or name)},
        "tagType": "AtomicTag",
    }


def memory_member(name, kind, default):
    """A memory tag -- MES-side state the device neither reads nor writes."""
    return {
        "name": name,
        "dataType": TAG_DTYPE[kind],
        "valueSource": "memory",
        "defaultValue": default,
        "tagType": "AtomicTag",
    }


def expr_member(name, kind, expression):
    """A derived tag -- protocol decode over a raw register word. Expression
    syntax is C-style (=, &&, !), NOT Python keywords, which fail silently
    as falsy."""
    return {
        "name": name,
        "dataType": TAG_DTYPE[kind],
        "valueSource": "expr",
        "expression": expression,
        "tagType": "AtomicTag",
    }


def folder(name, members):
    """A UDT folder member -- groups children by audience, not by address."""
    return {"name": name, "tagType": "Folder", "tags": members}


def flatten_opc(members):
    """Yield (address, kind) for every OPC member, recursing into folders.
    Memory and expression members are skipped -- they have no device address.
    Bit-addressed members (HR4.12) collapse onto their containing word (HR4),
    deduped, because the simulator serves whole registers.

    Dedup is GLOBAL, not per-folder: HR4 is reached from Weight, Verdict and
    Protocol/Live alike, so the recursive results must be merged through the
    same membership test as the local ones or the word gets a row per folder
    that touches it."""
    out = []
    for m in members:
        if m.get("tagType") == "Folder":
            for pair in flatten_opc(m["tags"]):
                if pair not in out:
                    out.append(pair)
        elif m.get("valueSource") == "opc":
            addr = m["opcItemPath"]["binding"].split("}")[-1]
            word = addr.split(".")[0]
            kind = "bool" if m["dataType"] == "Boolean" else (
                   "real" if m["dataType"] == "Float8" else
                   "str" if m["dataType"] == "String" else "int")
            if addr != word:
                kind = "int"   # the containing word, not the bit
            if (word, kind) not in out:
                out.append((word, kind))
    return out


# ---- IND570 scale over Modbus TCP -------------------------------------------
# Register map: PLC Interface Manual (doc 30205335 rev 12) Sec 5.4.4 + Table 5-3,
# Floating Point format. Mettler's 4000xx/4010xx are Modicon DISPLAY convention;
# the real register numbers are 1 and 1025 -- hence HR1 / HR1026, not HR400001.
# Read and write areas share one holding-register space, offset by 1024.
#
#   slot 1 (live, parked on command 11 = report net weight)
#     HR1     Command Response      HR1026   Command        (write)
#     HRF2    FP value (regs 2-3)
#     HR4     Scale Status
#   slot 2 (command scratchpad -- setpoint loads never interrupt the live read)
#     HR5     Command Response      HR1029   Command        (write)
#     HRF6    FP value (regs 6-7)   HRF1030  FP Load Value  (write)
#
# Scale Status bits: 0 Under / 2 OK / 4 Over (over/under target mode),
# 5 always 1, 12 Motion, 13 Net mode, 14 Data Integrity 2, 15 Data OK.
# Command Response bits: 8-12 FP Indicator, 13 Data Integrity 1, 14-15 Cmd Ack.

_LIVE_CR = "{[.]Protocol/Live/CommandResponse}"
_CMD_CR = "{[.]Protocol/Command/CommandResponse}"


def _bitfield(word, lo, hi):
    """Decode an inclusive bit range out of a 16-bit word as an integer.
    getBit(number, position) is zero-indexed with the LSB at position 0,
    which matches Mettler's bit numbering directly."""
    return " + ".join("getBit(%s, %d) * %d" % (word, b, 2 ** i)
                      for i, b in enumerate(range(lo, hi + 1)))


def scale_members():
    return [
        folder("Weight", [
            opc_member("Net",        "real", "HRF2"),
            opc_member("InMotion",   "bool", "HR4.12"),
            opc_member("IsValid",    "bool", "HR4.15"),
            # FP Indicator 1 == net weight. 0 == gross, which is what a
            # power-cycled terminal reports when its command register is 0 --
            # plausible, well-formed, wrong. This is the guard.
            expr_member("SourceIsNet", "bool",
                        "{[.]Protocol/Live/FpIndicator} = 1"),
            memory_member("Uom", "str", "{WeightUom}"),
        ]),
        folder("Trigger", [
            # Physical button. Bit 8 LATCHES on ENTER and is cleared by command
            # 75; bits 9-11 are discrete inputs and are live state, so a press
            # shorter than the poll interval is invisible. All four are exposed
            # because which one the button is wired to is a commissioning
            # unknown -- press it and watch which moves. See spec 5.1.2.
            opc_member("EnterKey", "bool", "HR4.8"),
            opc_member("Input1",   "bool", "HR4.9"),
            opc_member("Input2",   "bool", "HR4.10"),
            opc_member("Input3",   "bool", "HR4.11"),
        ]),
        folder("Verdict", [
            opc_member("Under", "bool", "HR4.0"),
            opc_member("Ok",    "bool", "HR4.2"),
            opc_member("Over",  "bool", "HR4.4"),
            expr_member("State", "str",
                        "if({[.]Verdict/Ok}, 'Ok', "
                        "if({[.]Verdict/Under}, 'Under', "
                        "if({[.]Verdict/Over}, 'Over', 'Unknown')))"),
        ]),
        folder("Setpoint", [
            memory_member("Target",       "real", 0.0),
            memory_member("Tolerance",    "real", 0.0),
            memory_member("Apply",        "bool", False),
            memory_member("ActiveTarget", "real", 0.0),
            memory_member("ActiveTolerance", "real", 0.0),
            memory_member("State",        "str",  "Idle"),
        ]),
        folder("Protocol", [
            folder("Live", [
                opc_member("Command",         "int",  "HR1026"),
                opc_member("CommandResponse", "int",  "HR1"),
                opc_member("Status",          "int",  "HR4"),
                opc_member("Integrity1",      "bool", "HR1.13"),
                opc_member("Integrity2",      "bool", "HR4.14"),
                expr_member("FpIndicator", "int", _bitfield(_LIVE_CR, 8, 12)),
            ]),
            folder("Command", [
                opc_member("Command",         "int",  "HR1029"),
                opc_member("LoadValue",       "real", "HRF1030"),
                opc_member("CommandResponse", "int",  "HR5"),
                opc_member("EchoValue",       "real", "HRF6"),
                expr_member("FpIndicator", "int", _bitfield(_CMD_CR, 8, 12)),
                expr_member("CommandAck",  "int", _bitfield(_CMD_CR, 14, 15)),
            ]),
        ]),
    ]


# UDT type -> (members, has WriteDisplayEnabled memory member).
# Members are either (name, kind) tuples -- address derived from the name --
# or already-built member dicts (ScaleStation's folder tree).
CATALOG = {
    "ScaleStation":            (scale_members(), False),
    "SerializedMipStation":    (SERIALIZED, True),
    "NonSerializedMipStation": (NONSERIALIZED, True),
    "TrayInspectionStation":   (TRAY, True),
}


def write_display_member():
    """Per-instance config: HMI-display writes gated off by default (spec Sec 5.1)."""
    return {
        "name": "WriteDisplayEnabled",
        "dataType": "Boolean",
        "valueSource": "memory",
        "defaultValue": False,
        "tagType": "AtomicTag",
    }


def build_members(type_name):
    """The type's member tree, minus WriteDisplayEnabled.

    CATALOG entries are either (name, kind) tuples -- the address is derived
    from the name -- or already-built member dicts (ScaleStation's folder
    tree, whose names and addresses are decoupled)."""
    members = CATALOG[type_name][0]
    return [m if isinstance(m, dict) else opc_member(m[0], m[1])
            for m in members]


def build_udt_def(type_name):
    has_wde = CATALOG[type_name][1]
    tags = build_members(type_name)
    if has_wde:
        tags.append(write_display_member())
    params = {
        "OpcServer": {"dataType": "String", "value": OPC_SERVER_DEFAULT},
        "Device": {"dataType": "String", "value": SIM_DEVICE},
        "BasePath": {"dataType": "String", "value": ""},
    }
    if type_name == "ScaleStation":
        # MPP's terminals are configured in pounds (verified at commissioning
        # via command 30, report units). Weight/Uom mirrors this parameter.
        params["WeightUom"] = {"dataType": "String", "value": "lb"}
    return {
        "name": type_name,
        "tagType": "UdtType",
        "parameters": params,
        "tags": tags,
    }


def build_instance(device_code, type_name):
    """Dev instance: points at the sim. BasePath carries the trailing separator."""
    return {
        "name": device_code,
        "tagType": "UdtInstance",
        "typeId": type_name,
        "parameters": {
            "OpcServer": {"dataType": "String", "value": OPC_SERVER_DEFAULT},
            "Device": {"dataType": "String", "value": SIM_DEVICE},
            "BasePath": {"dataType": "String", "value": device_code + "/"},
        },
    }


def load_devices():
    """[(DeviceCode, DeviceType), ...] in manifest order (excludes Active=0 rows;
    the manifest already omits 5G0 Line 2 Backup / 6MA-2 per spec Sec 3.2)."""
    devices = []
    with open(MANIFEST, "r") as f:
        for row in csv.DictReader(f):
            devices.append((row["DeviceCode"], row["DeviceType"]))
    return devices


def dump_json(obj, path):
    # sort_keys=True mirrors Designer's canonical (alphabetical) key order, so a
    # later Designer re-export produces a minimal diff. Literal '=' in the
    # binding strings is valid JSON and imports fine; Designer may re-serialize
    # it to = on a subsequent export (cosmetic only).
    with open(path, "w") as f:
        json.dump(obj, f, indent=2, sort_keys=True)
        f.write("\n")


def main():
    devices = load_devices()

    # 1) UDT definitions
    udt_dir = os.path.join(TAGS_DIR, "udt")
    if not os.path.isdir(udt_dir):
        os.makedirs(udt_dir)
    for type_name in CATALOG:
        dump_json(build_udt_def(type_name), os.path.join(udt_dir, type_name + ".json"))

    # 2) instances (one Folder holding all devices)
    inst_dir = os.path.join(TAGS_DIR, "instances")
    if not os.path.isdir(inst_dir):
        os.makedirs(inst_dir)
    folder = {
        "name": "PlcDevices",
        "tagType": "Folder",
        "tags": [build_instance(code, t) for code, t in devices],
    }
    dump_json(folder, os.path.join(inst_dir, "PlcDevices.json"))

    # 3) sim program CSV -- one writeable row per member per device
    sim_dir = os.path.join(TAGS_DIR, "sim")
    if not os.path.isdir(sim_dir):
        os.makedirs(sim_dir)
    sim_path = os.path.join(sim_dir, "MPP_Sim_program.csv")
    with open(sim_path, "w") as f:
        f.write("Time Interval, Browse Path, Value Source, Data Type\n")
        w = csv.writer(f, quoting=csv.QUOTE_ALL, lineterminator="\n")
        for code, type_name in devices:
            # The browse path carries the ADDRESS, not the friendly member
            # name -- the simulator serves register addresses, so a row named
            # <device>/Net would never match the UDT's {BasePath}HRF2 path.
            for address, kind in flatten_opc(build_members(type_name)):
                w.writerow(["0", "%s/%s" % (code, address),
                            SIM_LITERAL[kind], SIM_DTYPE[kind]])
            # WriteDisplayEnabled is a UDT memory member, NOT an OPC/sim tag -> skip.

    # Count the LEAF OPC members that actually reached the CSV -- len() over
    # the catalog entry would count folders, and would include the memory and
    # expression members that never get a sim row.
    n_members = sum(len(flatten_opc(build_members(t))) for _, t in devices)
    print("Wrote 4 UDT defs, %d instances, %d sim rows (%d devices)."
          % (len(devices), n_members, len(devices)))


if __name__ == "__main__":
    main()
