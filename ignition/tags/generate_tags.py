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
SCALE = [
    ("NET_DataReady", "bool"), ("NET_NetWeightValue", "real"),
    ("NET_NetWeightUOM", "str"), ("NET_TargetWeightMetFlag", "bool"),
    ("NET_PartNumber", "str"), ("TRG_TargetWeightValue", "real"),
    ("TRG_TargetWeightUOM", "str"), ("TRG_ToleranceWeightValue", "real"),
    ("TRG_SendMessage", "bool"),
]
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

# UDT type -> (opc members, has WriteDisplayEnabled memory member)
CATALOG = {
    "ScaleStation":            (SCALE, False),
    "SerializedMipStation":    (SERIALIZED, True),
    "NonSerializedMipStation": (NONSERIALIZED, True),
    "TrayInspectionStation":   (TRAY, True),
}


def opc_member(name, kind):
    """One OPC AtomicTag member -- opcServer + opcItemPath are parameter binds.
    Member name appended directly to {BasePath} (separator lives in BasePath)."""
    return {
        "name": name,
        "dataType": TAG_DTYPE[kind],
        "valueSource": "opc",
        "opcServer": {"bindType": "parameter", "binding": "{OpcServer}"},
        "opcItemPath": {"bindType": "parameter",
                        "binding": "ns=1;s=[{Device}]{BasePath}" + name},
        "tagType": "AtomicTag",
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


def build_udt_def(type_name):
    members, has_wde = CATALOG[type_name]
    tags = [opc_member(n, k) for n, k in members]
    if has_wde:
        tags.append(write_display_member())
    return {
        "name": type_name,
        "tagType": "UdtType",
        "parameters": {
            "OpcServer": {"dataType": "String", "value": OPC_SERVER_DEFAULT},
            "Device": {"dataType": "String", "value": SIM_DEVICE},
            "BasePath": {"dataType": "String", "value": ""},
        },
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
            members, has_wde = CATALOG[type_name]
            for name, kind in members:
                w.writerow(["0", "%s/%s" % (code, name), SIM_LITERAL[kind], SIM_DTYPE[kind]])
            # WriteDisplayEnabled is a UDT memory member, NOT an OPC/sim tag -> skip.

    n_members = sum(len(CATALOG[t][0]) for _, t in devices)
    print("Wrote 4 UDT defs, %d instances, %d sim rows (%d devices)."
          % (len(devices), n_members, len(devices)))


if __name__ == "__main__":
    main()
