"""Guard the ladder-file segmentation in decode_rslogix500_rss.py.

A .RSS carries its ladder files as fixed-width records in PROGRAM FILES:

    03 80 | RR RR | 01 00 | <10-byte NUL-padded name> | FF FF | 00 | RR RR
           rungs            name                       file#      rungs again

The name field is OFTEN BLANK. MPP's own programs ship unnamed ladder files --
59BCH has nothing but unnamed files, MPP_COG's file 2 is unnamed, and SORTCAGE
carries a 1-rung unnamed file 5. The original regex required at least one
printable name character, so it emitted no file header for those; their rungs
got folded into the preceding file and the rung numbering never restarted. On
59BCH that meant a flat 53-rung listing with no file boundaries at all, and on
SORTCAGE it meant a whole ladder file vanished from the output with no warning.

The expected inventories below were read out of the raw bytes by hand, so they
are independent of the code under test. Rung counts include the END rung, which
is how RSLogix itself counts them.

Run: python -m pytest reference/scripts/test_decode_rslogix500_rss.py
"""

import os
import re
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import decode_rslogix500_rss as dec  # noqa: E402

RSS_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, "PLC scripts")

# (file number, name, rungs incl. END) in stream order.
EXPECTED = {
    "59BCH":    [(2, "", 39), (3, "", 15)],
    "6FB":      [(2, "MAIN", 32), (3, "HOST", 11)],
    "MPPMACH":  [(2, "MAIN", 69), (3, "VISION", 13), (4, "HOST", 10)],
    "MPP_COG":  [(2, "", 21), (3, "VISION", 17)],
    "SORTCAGE": [(2, "MAIN", 24), (3, "VISION", 28), (4, "HOST", 2),
                 (5, "", 1)],
}

HEADER = re.compile(r"^=== LAD (\d+)(?: (\S+))? \((\d+) rungs incl\. END\)$")


def rss(name):
    path = os.path.join(RSS_DIR, name + ".RSS")
    if not os.path.exists(path):
        pytest.skip("%s.RSS not present" % name)
    return path


def headers(text):
    out = []
    for line in text.splitlines():
        m = HEADER.match(line)
        if m:
            out.append((int(m.group(1)), m.group(2) or "", int(m.group(3))))
    return out


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_every_ladder_file_is_found_named_or_not(name):
    assert dec.ladder_files(dec.program(rss(name))) == EXPECTED[name]


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_the_listing_carries_one_header_per_ladder_file(name):
    assert headers(dec.decode(rss(name))) == EXPECTED[name]


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_rung_numbering_restarts_inside_every_file(name):
    """The symptom that started this: without a header the rungs of an unnamed
       file kept counting up from the previous file, so rung 039 of 59BCH was
       really rung 000 of its second (unnamed) ladder file.

       A file may contribute no rung line at all -- SORTCAGE's file 5 is one
       rung long and that rung is END, which carries no instructions -- so the
       assertion is that whatever each file's FIRST printed rung is, it is 000."""
    firsts, pending = [], False
    for line in dec.decode(rss(name)).splitlines():
        if HEADER.match(line):
            firsts.append(None)
            pending = True
            continue
        m = re.match(r"^  (\d{3}): ", line)
        if m and pending:
            firsts[-1] = int(m.group(1))
            pending = False
    assert len(firsts) == len(EXPECTED[name])
    assert [f for f in firsts if f is not None], "no rungs printed at all"
    assert all(f == 0 for f in firsts if f is not None), firsts


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_no_rung_number_exceeds_its_file_rung_count(name):
    """A rung numbered past its file's own count means rungs leaked across a
       boundary -- the exact corruption an unnamed file used to cause."""
    limits = dict((n, r) for n, _, r in EXPECTED[name])
    current = None
    for line in dec.decode(rss(name)).splitlines():
        m = HEADER.match(line)
        if m:
            current = limits[int(m.group(1))]
            continue
        m = re.match(r"^  (\d{3}): ", line)
        if m and current is not None:
            assert int(m.group(1)) < current, line


def test_an_all_nul_name_field_reads_as_blank_not_as_nul_bytes():
    files = dec.ladder_files(dec.program(rss("59BCH")))
    assert all(nm == "" for _, nm, _ in files)
