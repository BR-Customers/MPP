"""BlueRidge.Lots.IdentifierSequence - thin access to the row-locked next-value
   sequence proc. Wrappers only; no business logic."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def next(code):
    """Atomically fetch the next value for the named identifier sequence.
       Returns the {Value: ...} row dict, or None."""
    BlueRidge.Common.Util.log("code=%s" % code)
    return BlueRidge.Common.Db.execOne(
        "lots/IdentifierSequence_Next",
        {"code": code},
    )
