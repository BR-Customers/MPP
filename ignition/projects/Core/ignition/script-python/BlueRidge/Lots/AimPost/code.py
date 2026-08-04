"""BlueRidge.Lots.AimPost - the ONE definition of 'post a serial to AIM'.

   Both callers use postOne: the synchronous path in Container.complete, and the
   60s retry sweep (AimPostTimer -> retryTick). Having one definition is the point -
   retry can never drift from first-attempt behaviour.

   postOne RE-READS the payload on every attempt rather than trusting a snapshot, so
   a row snapshotted with a NULL customer part self-heals on the next attempt with
   no requeue, no manual step. (Lots.AimShipperIdPool_GetForPost COALESCEs the
   frozen snapshot against Parts.ufn_AimCustomerPartNumber(Item.PartNumber) - the
   AIM customer part is DERIVED from the item's part number, not a separately
   maintained field - Migration 0051, 2026-08-04.)

   AimHttp.postSerial's error text on a non-2xx is "HTTP <code>: <AIM's message>"
   (e.g. "HTTP 403: Not logged in - AIM Mobility must be restarted.") - that string
   is passed through unchanged into LastPostError / the returned error, because a
   supervisor reads it verbatim to diagnose the failure.

   Nothing here raises. A container completion must never fail because AIM is down."""


def postOne(aimShipperId):
    """Post one owed serial to AIM and record the outcome.
       Returns {ok, outcome, error, itemPartNumber}. Outcomes:
         posted             - AIM accepted it
         already_posted     - nothing owed; no call made
         not_found          - no such pool row
         incomplete_payload - LotNumber and/or Quantity is NULL on the pool row;
                               NO call made. Reachable e.g. because
                               ContainerTray_Close never sets FinishedGoodLotId
                               and a caller (AssemblyPlc) can complete a container
                               without ever routing through the proc that does.
                               AIM has no acceptable placeholder for a missing lot
                               or quantity - str(None) would silently ship the
                               literal text "None" on a Honda-facing label, which
                               is worse than not posting at all.
         failed              - AIM refused or was unreachable"""
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
        lotNumber = row.get("LotNumber")
        quantity = row.get("Quantity")

        # No "missing customer part" branch here: CustomerPartNumber is either the
        # frozen completion-time snapshot or, via AimShipperIdPool_GetForPost's
        # COALESCE, Parts.ufn_AimCustomerPartNumber(Item.PartNumber) - and
        # PartNumber is NOT NULL, so this can never be empty for a real item
        # (Migration 0051, 2026-08-04).

        # Never let str(None) reach AIM as the literal text "None" for a missing
        # lot number or quantity - treat it the same as a missing customer part:
        # do not call AIM, record why, let the operator/supervisor see it plainly.
        if lotNumber is None or quantity is None:
            missing = []
            if lotNumber is None:
                missing.append("lot number")
            if quantity is None:
                missing.append("quantity")
            msg = "AIM payload incomplete for %s: missing %s." % (
                itemPartNumber or "this item", " and ".join(missing))
            BlueRidge.Lots.AimPool.recordPostResult(row.get("Id"), False, msg)
            return {"ok": False, "outcome": "incomplete_payload", "error": msg,
                    "itemPartNumber": itemPartNumber}

        res = BlueRidge.Lots.AimHttp.postSerial(
            aimShipperId, customerPart, quantity, lotNumber)
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
