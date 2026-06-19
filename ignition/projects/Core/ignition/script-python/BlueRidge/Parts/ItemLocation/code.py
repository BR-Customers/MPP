"""BlueRidge.Parts.ItemLocation - thin read access to ItemLocation eligibility.

   Wrappers only; no business logic. Arc 2 Phase 4 (Movement Scan FDS-02-012)."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def checkEligibility(itemId, locationId):
    """Advisory eligibility read (Direct U BomDerived). Returns
       {IsEligible, Path} ('Direct'/'BomDerived'/None) or None. The
       authoritative gate is Lots.Lot_MoveToValidated; this drives UI feedback."""
    BlueRidge.Common.Util.log("itemId=%s locationId=%s" % (itemId, locationId))
    return BlueRidge.Common.Db.execOne(
        "parts/ItemLocation_CheckEligibility",
        {"itemId": _u(itemId), "locationId": _u(locationId)},
    )


def checkEligibilityOrEmpty(itemId, locationId):
    """Binding-safe variant: always returns a fully-shaped dict
       {IsEligible, Path} (never None) for pre-declared bound custom props."""
    r = checkEligibility(itemId, locationId)
    if not r:
        return {"IsEligible": False, "Path": None}
    return r
