"""BlueRidge.Lots.AimPost - the ONE definition of 'post a serial to AIM'.

   Both callers use postOne: the synchronous path in Container.complete, and the
   60s retry sweep (AimPostTimer -> retryTick). Having one definition is the point -
   retry can never drift from first-attempt behaviour.

   postOne RE-READS the payload on every attempt rather than trusting a snapshot, so
   a row that failed because its item had no AIM customer part self-heals the moment
   someone fills that field in - no requeue, no manual step. (Lots.AimShipperIdPool_
   GetForPost COALESCEs the frozen snapshot against the live Parts.Item value.)

   AimHttp.postSerial's error text on a non-2xx is "HTTP <code>: <AIM's message>"
   (e.g. "HTTP 403: Not logged in - AIM Mobility must be restarted.") - that string
   is passed through unchanged into LastPostError / the returned error, because a
   supervisor reads it verbatim to diagnose the failure.

   Nothing here raises. A container completion must never fail because AIM is down."""


def postOne(aimShipperId):
    """Post one owed serial to AIM and record the outcome.
       Returns {ok, outcome, error, itemPartNumber}. Outcomes:
         posted           - AIM accepted it
         already_posted   - nothing owed; no call made
         not_found        - no such pool row
         no_customer_part - item has no AimCustomerPartNumber; NO call made
         failed           - AIM refused or was unreachable"""
    from java.lang import Throwable
    try:
        rows = BlueRidge.Lots.AimPool.getForPost(aimShipperId) or []
        if not rows:
            return {"ok": False, "outcome": "not_found",
                    "error": "No AIM pool row for %s." % aimShipperId,
                    "itemPartNumber": None}
        row = rows[0]
        if row.get("PostedAt") is not None:
            return {"ok": True, "outcome": "already_posted", "error": None,
                    "itemPartNumber": row.get("ItemPartNumber")}

        customerPart = row.get("CustomerPartNumber")
        itemPartNumber = row.get("ItemPartNumber")
        if not customerPart:
            msg = "No AIM customer part configured for %s." % (itemPartNumber or "this item")
            BlueRidge.Lots.AimPool.recordPostResult(row.get("Id"), False, msg)
            return {"ok": False, "outcome": "no_customer_part", "error": msg,
                    "itemPartNumber": itemPartNumber}

        res = BlueRidge.Lots.AimHttp.postSerial(
            aimShipperId, customerPart, row.get("Quantity"), row.get("LotNumber"))
        BlueRidge.Lots.AimPool.recordPostResult(
            row.get("Id"), res.get("ok"), res.get("error"))
        if res.get("ok"):
            return {"ok": True, "outcome": "posted", "error": None,
                    "itemPartNumber": itemPartNumber}
        return {"ok": False, "outcome": "failed", "error": res.get("error"),
                "itemPartNumber": itemPartNumber}
    except Throwable, t:
        BlueRidge.Common.Util.log("postOne %s failed: %s" % (aimShipperId, t), level="error")
        return {"ok": False, "outcome": "failed", "error": str(t), "itemPartNumber": None}
    except Exception, e:
        BlueRidge.Common.Util.log("postOne %s failed: %s" % (aimShipperId, e), level="error")
        return {"ok": False, "outcome": "failed", "error": str(e), "itemPartNumber": None}


def retryTick(batch=50):
    """Sweep rows owed to AIM. Each row is individually guarded so one failure cannot
       abort the batch; the whole tick is guarded so a timer can never throw. Order
       does not matter - AIM accepts serials out of order (verified 2026-07-31)."""
    from java.lang import Throwable
    stats = {"attempted": 0, "posted": 0, "failed": 0}
    try:
        for row in (BlueRidge.Lots.AimPool.listUnposted(batch) or []):
            serial = row.get("AimShipperId")
            stats["attempted"] += 1
            try:
                res = postOne(serial)
                if res.get("ok"):
                    stats["posted"] += 1
                else:
                    stats["failed"] += 1
            except Throwable, t:
                stats["failed"] += 1
                BlueRidge.Common.Util.log("retryTick row %s: %s" % (serial, t), level="error")
            except Exception, e:
                stats["failed"] += 1
                BlueRidge.Common.Util.log("retryTick row %s: %s" % (serial, e), level="error")
        if stats["attempted"]:
            BlueRidge.Common.Util.log("retryTick %s" % stats)
    except Throwable, t:
        BlueRidge.Common.Util.log("retryTick failed: %s" % t, level="error")
    except Exception, e:
        BlueRidge.Common.Util.log("retryTick failed: %s" % e, level="error")
    return stats
