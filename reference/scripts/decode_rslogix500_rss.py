"""Decode an RSLogix 500 project (.RSS) into a readable ladder listing.

   Built 2026-09-11 to read the 6MA CH camera PLC without RSLogix installed.
   An .RSS is an OLE compound file; the interesting streams are zlib-compressed
   after a 16-byte header:
     PROGRAM FILES/ObjectData  - the ladder (MFC-serialized CRung / CBranchLeg /
                                 CIns objects; each instruction stores its operand
                                 strings, then its compiled opcode)
     MEM DATABASE/ObjectData   - address symbols + comments

   Output: every ladder file and rung, instructions in left-to-right order with
   branches FLATTENED (legs listed one after another), each followed by the
   comments of the addresses it touches. Operands that carry a cached value are
   shown with it (e.g. "MOV 0 -> N7:0" where the cached dest value is dropped).

   The opcode names come from one program (6MA): XIC/XIO/OTE/OTL/OTU/MOV/TON/
   CTU/RES/MSG are certain (they agree with the comments and the logic);
   EQU?/NEQ?/LIM? are inferred from operand shape. Anything else prints as
   0xNN with raw operands -- check it in RSLogix before relying on it.

   Usage:  pip install olefile
           python decode_rslogix500_rss.py <project.RSS> [out.txt]
"""

import re
import struct
import sys
import zlib

import olefile

OPCODES = {
    0x39: "XIC", 0x3a: "XIO", 0x2f: "OTE", 0x30: "OTL", 0x31: "OTU",
    0x0f: "TON", 0x56: "TON(1s)", 0x11: "CTU", 0x13: "RES", 0x15: "JSR",
    0x1c: "MOV", 0x22: "COP", 0x27: "ADD", 0x32: "EQU?", 0x33: "NEQ?",
    0x3f: "LIM?", 0x7c: "ACL", 0x84: "ARL", 0xab: "ONS", 0xb6: "MSG",
}

# MFC class-map tags that are stable for a RSLogix 500 program: CLadFile is
# class 3; the SYS0/SYS1 file objects take 4 and 5, so the first ladder file
# defines CRung = 7, CBranchLeg = 9, CIns = 11. A rung starts with a CRung ref
# immediately followed by its first CBranchLeg ref.
TAG_RUNG = b"\x07\x80\x09\x80"
TAG_INS = b"\x0b\x80"
TAG_FILE = re.compile(rb"\x03\x80(..)\x01\x00([A-Za-z0-9_ ]{1,10})\x00*(..)", re.S)


def stream(ole, name):
    data = ole.openstream(name).read()
    if len(data) > 18 and data[16:18] == b"\x78\x9c":
        return zlib.decompress(data[16:])
    return data


def comments(memdb):
    """{address: 'SYMBOL comment'} from MEM DATABASE, addresses normalized to
       RSLogix form (N0007:010 -> N7:10, S0002 -> S)."""
    out = {}
    for m in re.finditer(rb"([\x05-\x14])([A-Z]{1,3}\d{4}:\d{3}(?:/\d{2})?)", memdb):
        if m.group(1)[0] != len(m.group(2)):
            continue
        p = m.end()
        fields = []
        for _ in range(6):                      # symbol + up to 5 comment lines
            n = memdb[p]
            fields.append(memdb[p + 1:p + 1 + n].decode("latin1"))
            p += 1 + n
        sym, lines = fields[0], [f for f in fields[1:] if f]
        t, f, e, b = re.match(r"([A-Z]+)0*(\d+):0*(\d+)(?:/0*(\d+))?",
                              m.group(2).decode()).groups()
        addr = ("S" if t == "S" else "%s%s" % (t, f)) + ":%s" % e + ("/%s" % b if b else "")
        text = " ".join(([sym] if sym else []) + lines)
        if text:
            out[addr] = text
    return out


def instructions(prog):
    """[(offset, opcode, [operands])] -- every CIns in stream order."""
    out, i = [], 0
    while i < len(prog) - 4:
        if prog[i:i + 2] == TAG_INS:
            n = struct.unpack_from("<H", prog, i + 2)[0]
            p, ops, ok = i + 4, [], 0 < n < 20
            for _ in range(n if ok else 0):
                s = prog[p + 1:p + 1 + prog[p]]
                if not all(0x20 <= c < 0x7f for c in s):
                    ok = False
                    break
                ops.append(s.decode())
                p += 1 + prog[p]
            if ok and p + 10 < len(prog):
                op = struct.unpack_from("<H", prog, p + 2)[0]
                size = struct.unpack_from("<H", prog, p + 8)[0]
                code = prog[p + 10:p + 10 + size]
                if code and code[0] == op & 0xff:
                    out.append((i, op, ops))
                    i = p + 10 + size
                    continue
        i += 1
    return out


def fmt(op, ops):
    name = OPCODES.get(op, "0x%02x" % op)
    if name == "MOV" and len(ops) == 4:
        return "MOV %s -> %s" % (ops[0], ops[2])
    if name == "ADD" and len(ops) == 6:
        return "ADD %s + %s -> %s" % (ops[0], ops[2], ops[4])
    if name in ("EQU?", "NEQ?") and len(ops) == 4:
        return "%s %s , %s" % (name, ops[0], ops[2])
    if name == "LIM?" and len(ops) == 6:
        return "LIM? %s <= %s <= %s" % (ops[0], ops[2], ops[4])
    if name.startswith("TON") and len(ops) == 4:
        return "%s %s base %s pre %s" % (name, ops[0], ops[1], ops[2])
    if name == "CTU" and len(ops) == 3:
        return "CTU %s pre %s" % (ops[0], ops[1])
    if name == "MSG" and len(ops) >= 4:
        return "MSG %s (%s / %s)" % (ops[0], ops[2], ops[3])
    return "%s %s" % (name, " ".join(ops))


def decode(path):
    ole = olefile.OleFileIO(path)
    prog = stream(ole, "PROGRAM FILES/ObjectData")
    notes = comments(stream(ole, "MEM DATABASE/ObjectData"))

    events = [(m.start(), "rung", None) for m in re.finditer(re.escape(TAG_RUNG), prog)]
    first_rung = prog.find(b"CRung")                 # rung 0 of the first file
    if first_rung > 0:
        events.append((first_rung, "rung", None))
    for m in TAG_FILE.finditer(prog):
        rungs = struct.unpack("<H", m.group(1))[0]
        events.append((m.start(), "file", "%s (%d rungs incl. END)"
                       % (m.group(2).decode().strip(), rungs)))
    events += [(o, "ins", fmt(op, ops)) for o, op, ops in instructions(prog)]
    events.sort(key=lambda e: e[0])

    lines, rung, current = [], -1, None

    def flush():
        if current:
            lines.append("  %03d: %s" % (rung, "  |  ".join(current)))
            seen = set()
            for text in current:
                for a in re.findall(r"[A-Z]{1,3}\d*:\d+(?:\.\d+)?(?:/\d+)?", text):
                    if a in notes and a not in seen:
                        seen.add(a)
                        lines.append("         ; %s = %s" % (a, notes[a]))

    for _, kind, text in events:
        if kind == "file":
            flush()
            lines += ["", "=== LAD %s" % text]
            rung, current = -1, None
        elif kind == "rung":
            flush()
            rung, current = rung + 1, []
        elif current is not None:
            current.append(text)
    flush()
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    text = decode(sys.argv[1])
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
