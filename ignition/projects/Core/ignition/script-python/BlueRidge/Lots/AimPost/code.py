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

   Nothing here raises. A container completion must never fail because AIM is down.

   FAILURE LOG (2026-10-29, migration 0116; MPP request 2026-09-16): every failing
   outcome of postOne -- failed, incomplete_payload, not_found, an exception -- writes
   ONE Audit.FailureLog row (entity Container, event AimPostFailed) carrying the
   container's cell as Location, the LOT named in the payload, and the metadata, BUT
   ONLY WHILE AIM POSTING IS SWITCHED ON. Posting switched off (AimPostingEnabled = 0)
   writes nothing, from any caller -- decided with Jacques 2026-10-29: it ships off and
   is turned off on purpose, so a row per owed container per tick would never end.
   An outage with posting ON is logged in full: retryTick writes a row per owed row per
   tick, accepted knowingly. AimHttp writes InterfaceLog only; this module writes the
   FailureLog row because it is the layer that knows the container, LOT and location."""

_PROC = "BlueRidge.Lots.AimPost.postOne"


def _logFailure(row, reason, appUserId, terminalLocationId, caller, httpRes=None, attempted=False):
    """Write the one FailureLog row for a failed postOne attempt. No-op while AIM posting
       is switched off. Never raises (FailureLog.record never raises; postingEnabled()
       reads off on error)."""
    if not BlueRidge.Lots.AimHttp.postingEnabled():
        return
    row = row or {}
    httpRes = httpRes or {}
    attempts = row.get("PostAttempts") or 0
    BlueRidge.Audit.FailureLog.record(
        procedureName=_PROC,
        failureReason=reason or "AIM post failed.",
        entityTypeCode="Container",
        eventTypeCode="AimPostFailed",
        appUserId=appUserId,
        entityId=row.get("ContainerId"),
        locationId=row.get("LocationId"),
        lotId=row.get("LotId"),
        meta={
            "aimShipperId":       row.get("AimShipperId"),
            "containerId":        row.get("ContainerId"),
            "lotNumber":          row.get("LotNumber"),
            "endpoint":           httpRes.get("endpoint"),
            "httpStatus":         httpRes.get("httpStatus"),
            "attempt":            (attempts + 1) if attempted else attempts,
            "terminalLocationId": terminalLocationId,
            "interfaceLogId":     httpRes.get("interfaceLogId"),
            "caller":             caller,
        })


def postOne(aimShipperId, appUserId=None, terminalLocationId=None, caller="complete"):
    """Post one owed serial to AIM and record the outcome.
       appUserId attributes a FailureLog row (the operator; Common.Util.systemAppUserId()
       from the retry timer). terminalLocationId and caller ('complete' / 'validateCrt' /
       'retry') only go into that row's metadata.
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
    row = {"AimShipperId": aimShipperId}
    try:
        rows = BlueRidge.Lots.AimPool.getForPost(aimShipperId) or []
        if not rows:
            msg = "No AIM pool row for %s." % aimShipperId
            _logFailure(row, msg, appUserId, terminalLocationId, caller)
            return {"ok": False, "outcome": "not_found", "error": msg,
                    "itemPartNumber": None}
        row = rows[0]
        if row.get("PostedAt") is not None:
            return {"ok": True, "outcome": "already_posted", "error": None,
                    "itemPartNumber": row.get("ItemPartNumber")}
        # Voided (migration 0111): the container was opened for rework and this
        # serial will never be used. Nothing is owed and nothing is sent; the
        # container posts its NEW serial when it completes again.
        if row.get("VoidedAt") is not None:
            return {"ok": True, "outcome": "voided", "error": None,
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
            _logFailure(row, msg, appUserId, terminalLocationId, caller)
            return {"ok": False, "outcome": "incomplete_payload", "error": msg,
                    "itemPartNumber": itemPartNumber}

        res = BlueRidge.Lots.AimHttp.postSerial(
            aimShipperId, customerPart, quantity, lotNumber,
            locationId=row.get("LocationId"), lotId=row.get("LotId"))
        BlueRidge.Lots.AimPool.recordPostResult(
            row.get("Id"), res.get("ok"), res.get("error"))
        if res.get("ok"):
            return {"ok": True, "outcome": "posted", "error": None,
                    "itemPartNumber": itemPartNumber}
        if not res.get("disabled"):
            _logFailure(row, res.get("error"), appUserId, terminalLocationId, caller,
                        httpRes=res, attempted=True)
        return {"ok": False, "outcome": "failed", "error": res.get("error"),
                "itemPartNumber": itemPartNumber}
    except Throwable, t:
        BlueRidge.Common.Util.log("postOne %s failed: %s" % (aimShipperId, t), level="error")
        _logFailure(row, "postOne raised: %s" % t, appUserId, terminalLocationId, caller)
        return {"ok": False, "outcome": "failed", "error": str(t), "itemPartNumber": None}
    except Exception, e:
        BlueRidge.Common.Util.log("postOne %s failed: %s" % (aimShipperId, e), level="error")
        _logFailure(row, "postOne raised: %s" % e, appUserId, terminalLocationId, caller)
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
                res = postOne(serial, BlueRidge.Common.Util.systemAppUserId(), None, "retry")
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
