# =============================================================================
# Demo: editDraft vs selected dirty-detection -- why type matters
#
# Run in the Designer Script Console (Tools -> Script Console). Paste, execute.
# Each block prints a labeled section so you can see the type drift play out
# in isolation from any actual Perspective binding.
#
# Background: dirty-detection on the Item Master / ContainerConfig / BOMs /
# Routes editors compares view.custom.editDraft != view.custom.selected. Both
# are Python dicts coming out of load(). The COMPARISON breaks because, once
# bidirectional bindings on text-fields / dropdowns settle, Perspective
# substitutes JVM types (java.lang.String, java.lang.Long, java.lang.Boolean)
# into editDraft -- WHILE selected stays Python-native (unicode/int/bool). The
# values are semantically equal; the wrappers are not. dict.__eq__ falls back
# to per-key __eq__, which for Java vs Python may or may not be true depending
# on the wrapper (java.lang.String == u"foo" usually works; java.math.BigDecimal
# vs Python float does NOT).
#
# Fix lives in BlueRidge.Common.Util.convertWrapperObjectToJson -- deep-unwraps
# through extractQualifiedValues, then jsonEncodes. Compare the strings.
# =============================================================================

from java.lang import String  as JavaString
from java.lang import Long    as JavaLong
from java.lang import Boolean as JavaBoolean
from java.math import BigDecimal


# -----------------------------------------------------------------------------
# (1) Right after load() runs, both dicts hold identical Python objects.
#     load() builds one dict literal and assigns dict(loaded) into both
#     selected and editDraft -- same source, two independent shallow copies.
# -----------------------------------------------------------------------------
loaded = {
    "Id":           1,
    "PartNumber":   u"5G0",
    "MaxParts":     500,
    "MaxLotSize":   None,
    "IsSerialized": False,
    "UnitWeight":   u"3.25",   # load() unicodes numerics for text-field bind
}

selected  = dict(loaded)
editDraft = dict(loaded)

print "== (1) Fresh load: pure Python types on both sides =="
print "  selected['PartNumber']  type:", type(selected["PartNumber"]).__name__
print "  selected['MaxParts']    type:", type(selected["MaxParts"]).__name__
print "  selected['UnitWeight']  type:", type(selected["UnitWeight"]).__name__
print "  selected == editDraft :", selected == editDraft           # True
print "  Dirty (raw !=)        :", selected != editDraft           # False
print


# -----------------------------------------------------------------------------
# (2) Once form components mount, bidirectional bindings fire and write back.
#     Ignition canonicalizes the value through the JVM, replacing Python
#     primitives with their Java equivalents. NO USER EDIT HAS HAPPENED.
# -----------------------------------------------------------------------------
editDraft["PartNumber"]   = JavaString(u"5G0")    # was Python unicode
editDraft["MaxParts"]     = JavaLong(500)         # was Python int
editDraft["IsSerialized"] = JavaBoolean(False)    # was Python bool
editDraft["UnitWeight"]   = JavaString(u"3.25")   # text-field bidi rewrite

print "== (2) After bidi writeback (no user edit yet) =="
print "  editDraft['PartNumber'] type:", type(editDraft["PartNumber"]).__name__
print "  editDraft['MaxParts']   type:", type(editDraft["MaxParts"]).__name__
print "  selected == editDraft :", selected == editDraft           # often True via __eq__ leniency
print "  Dirty (raw !=)        :", selected != editDraft           # but can flip False positive
print


# -----------------------------------------------------------------------------
# (3) The hard case -- BigDecimal from a numeric source. java.math.BigDecimal
#     does NOT __eq__ a Python float. This is where raw dict-compare reliably
#     produces false-positive drift.
# -----------------------------------------------------------------------------
editDraft["UnitWeight"] = BigDecimal("3.25")      # what a numeric writeback path may emit

print "== (3) BigDecimal vs Python unicode/float =="
print "  selected['UnitWeight']  :", repr(selected["UnitWeight"]),  type(selected["UnitWeight"]).__name__
print "  editDraft['UnitWeight'] :", repr(editDraft["UnitWeight"]), type(editDraft["UnitWeight"]).__name__
print "  BigDecimal('3.25') == u'3.25' :", BigDecimal("3.25") == u"3.25"   # False
print "  Dirty (raw !=)        :", selected != editDraft           # True -- false positive
print


# -----------------------------------------------------------------------------
# (4) Reconcile via deep-unwrap + JSON-encode. convertWrapperObjectToJson
#     calls extractQualifiedValues to turn ImmutableMap/JavaMap/QualifiedValue
#     into Python-native containers, then jsonEncodes for stable string
#     comparison. Java types serialize to their string form regardless of
#     wrapper class. Both sides come out the same string.
# -----------------------------------------------------------------------------
json_sel = BlueRidge.Common.Util.convertWrapperObjectToJson(selected)
json_drf = BlueRidge.Common.Util.convertWrapperObjectToJson(editDraft)

print "== (4) Deep-unwrap + jsonEncode (the actual fix) =="
print "  selected  JSON :", json_sel
print "  editDraft JSON :", json_drf
print "  Dirty (JSON !=):", json_sel != json_drf                   # False -- no real edit
print


# -----------------------------------------------------------------------------
# (5) Now do a REAL user edit and confirm dirty flips true.
# -----------------------------------------------------------------------------
editDraft["MaxParts"] = JavaLong(750)             # operator changed 500 -> 750

json_sel = BlueRidge.Common.Util.convertWrapperObjectToJson(selected)
json_drf = BlueRidge.Common.Util.convertWrapperObjectToJson(editDraft)

print "== (5) After real edit (MaxParts 500 -> 750) =="
print "  selected  JSON :", json_sel
print "  editDraft JSON :", json_drf
print "  Dirty (JSON !=):", json_sel != json_drf                   # True -- real change
print


# -----------------------------------------------------------------------------
# (6) QualifiedValue unwrap sanity check. When a runScript-bound expression
#     receives a tag-quality-wrapped value, .value (or .getValue()) yields
#     the underlying primitive. extractQualifiedValues handles this
#     recursively so nested QV-in-dict-in-list all flatten in one call.
# -----------------------------------------------------------------------------
from com.inductiveautomation.ignition.common.model.values import BasicQualifiedValue
from com.inductiveautomation.ignition.common.model.values import QualityCode

qv = BasicQualifiedValue(u"5G0", QualityCode.Good)

print "== (6) QualifiedValue unwrap =="
print "  raw qv               :", qv
print "  qv.value             :", qv.value                          # shortcut
print "  qv.getValue()        :", qv.getValue()                     # explicit method
print "  extracted            :", BlueRidge.Common.Util.extractQualifiedValues(qv)
print "  extracted (in dict)  :", BlueRidge.Common.Util.extractQualifiedValues({"x": qv})
print


# -----------------------------------------------------------------------------
# Summary -- when to use which:
#
#   value.value / value.getValue()     -- one-off, you have a single QV in hand
#   extractQualifiedValues(container)  -- you have a dict/list that MIGHT contain
#                                         wrapped values, want Python-native back
#   convertWrapperObjectToJson(obj)    -- dirty-detection or any comparison
#                                         across the bidi-binding boundary
# -----------------------------------------------------------------------------
