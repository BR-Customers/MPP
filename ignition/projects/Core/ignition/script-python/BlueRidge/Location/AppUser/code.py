"""BlueRidge.Location.AppUser - thin access to operator / AD auth procs.

   Wrappers only; no business logic."""

import system.security
import java.lang


def getUserList(includeDeprecated=False, textFilter=None):
    """List AppUsers for the Users management screen, optionally filtered by
       free text (matched against Initials / DisplayName / AdAccount).
       Returns list[dict]."""
    BlueRidge.Common.Util.log("includeDeprecated=%s textFilter=%s"
                              % (includeDeprecated, textFilter))
    return BlueRidge.Common.Db.execList(
        "location/AppUser_List",
        {"includeDeprecated": includeDeprecated, "filter": textFilter},
    )


def getUser(chosenId):
    """Read a single AppUser by Id. Returns a dict or None."""
    BlueRidge.Common.Util.log("id=%s" % chosenId)
    return BlueRidge.Common.Db.execOne(
        "location/AppUser_Get",
        {"id": chosenId},
    )


def createOperator(meta, appUserId):
    """Create a user from the operator editor. Initials + DisplayName always; an
       optional AdAccount + IgnitionRole link the row to an AD supervisor
       (empty -> NULL = operator-only). Returns {Status, Message, NewId}."""
    m = BlueRidge.Common.Util.extractQualifiedValues(meta) or {}
    attributes = {
        "initials":     m.get("initials"),
        "displayName":  m.get("displayName"),
        "adAccount":    (m.get("adAccount") or None),
        "ignitionRole": (m.get("ignitionRole") or None),
        "appUserId":    appUserId,
    }
    return createUser(attributes)


def createUser(attributes):
    """Create a new AppUser from an attributes dict
       (initials, displayName, adAccount, ignitionRole, appUserId).
       Initials must be unique. Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log("initials=%s" % attributes.get("initials"))
    if not attributes.get("appUserId"):
        attributes["appUserId"] = BlueRidge.Common.Util._currentAppUserId()
    return BlueRidge.Common.Db.execOne("location/AppUser_Create", attributes)


def deprecateUser(chosenId, appUserId):
    """Soft-delete (deprecate) an AppUser. Returns {Status, Message}."""
    BlueRidge.Common.Util.log("id=%s appUserId=%s" % (chosenId, appUserId))
    if not appUserId:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    return BlueRidge.Common.Db.execOne(
        "location/AppUser_Deprecate",
        {"id": chosenId, "appUserId": appUserId},
    )


def updateOperator(chosenId, meta, appUserId):
    """Update a user from the operator editor (Initials + DisplayName + optional
       AdAccount/IgnitionRole AD link; empty -> NULL). Returns {Status, Message}."""
    m = BlueRidge.Common.Util.extractQualifiedValues(meta) or {}
    attributes = {
        "id":           chosenId,
        "initials":     m.get("initials"),
        "displayName":  m.get("displayName"),
        "adAccount":    (m.get("adAccount") or None),
        "ignitionRole": (m.get("ignitionRole") or None),
        "appUserId":    appUserId,
    }
    return updateUser(attributes)


def updateUser(attributes):
    """Update an AppUser from an attributes dict keyed by Id
       (id, initials, displayName, adAccount, ignitionRole, appUserId).
       Returns {Status, Message}."""
    BlueRidge.Common.Util.log("initials=%s" % attributes.get("initials"))
    if not attributes.get("appUserId"):
        attributes["appUserId"] = BlueRidge.Common.Util._currentAppUserId()
    return BlueRidge.Common.Db.execOne("location/AppUser_Update", attributes)


def emptyMeta():
    """Blank meta dict for the editor's create-mode initialization."""
    return {
        "id":          None,
        "initials":    "",
        "displayName": "",
        "adAccount":   "",
        "ignitionRole": "",
    }


def getByInitials(initials):
    """Resolve an AppUser by shop-floor initials, INCLUDING deprecated rows.

       Initials are unique across the full lifecycle, so this is the history/
       attribution lookup (a retired operator's initials still resolve). For
       PRESENCE sign-in use getActiveByInitials instead -- a deprecated
       operator must never resolve into a new production stamp (FAT-USR-090).
       Returns a dict or None."""
    BlueRidge.Common.Util.log("initials=%s" % initials)
    return BlueRidge.Common.Db.execOne(
        "location/AppUser_GetByInitials",
        {"initials": initials},
    )


def getActiveByInitials(initials):
    """Resolve an ACTIVE (non-deprecated) AppUser by shop-floor initials.

       The presence-eligibility gate (FAT-USR-090): unknown AND deprecated
       initials both return None, so neither can sign in nor stamp a mutation.
       The DeprecatedAt filter is enforced in SQL (Location.AppUser_
       GetActiveByInitials), not here. Returns a dict or None."""
    BlueRidge.Common.Util.log("initials=%s" % initials)
    return BlueRidge.Common.Db.execOne(
        "location/AppUser_GetActiveByInitials",
        {"initials": initials},
    )


def create(data):
    """Create a new AppUser. Returns {Status, Message, NewId}.

       Shop-floor self-registration (UnknownInitials -> RegisterOperator) creates
       Operator-class rows: Initials + DisplayName only, AdAccount/IgnitionRole NULL.
       appUserId defaults to 1 (the bootstrap/system user) because nobody is
       authenticated at the Initials screen -- attribution policy, not a rule."""
    BlueRidge.Common.Util.log("data=%s" % data)
    params = {
        "initials":     (data.get("initials") or "").strip().upper(),
        "displayName":  data.get("displayName"),
        "adAccount":    data.get("adAccount"),
        "ignitionRole": data.get("ignitionRole"),
        "appUserId":    data.get("appUserId") or 1,
    }
    return BlueRidge.Common.Db.execMutation("location/AppUser_Create", params)


def authenticateAd(adAccount, actionCode=None, terminalLocationId=None, appUserId=None):
    """Authenticate / elevate an AD account for a protected action.
       Returns {Status, Message, AppUserId, IgnitionRole}."""
    BlueRidge.Common.Util.log(
        "adAccount=%s actionCode=%s terminalLocationId=%s appUserId=%s"
        % (adAccount, actionCode, terminalLocationId, appUserId)
    )
    params = {
        "adAccount":          adAccount,
        "actionCode":         actionCode,
        "terminalLocationId": terminalLocationId,
        "appUserId":          appUserId,
    }
    return BlueRidge.Common.Db.execMutation("location/AppUser_AuthenticateAd", params)


def getRoles(appUserId):
    """List the Ignition roles granted to an AppUser. Returns list[dict]."""
    BlueRidge.Common.Util.log("appUserId=%s" % appUserId)
    return BlueRidge.Common.Db.execList(
        "location/AppUser_GetRoles",
        {"appUserId": appUserId},
    )


def resolveForPresence(initials):
    """Resolve shop-floor initials to a fully-shaped presence dict for the
       Per-Mutation Initials Field. Always returns the SAME shape so the view's
       fully-declared custom prop never sees a missing key:

         {appUserId, initials, displayName, valid, checked}

       valid=False / displayName="" when the initials are blank, unrecognised,
       OR deprecated -- resolution goes through the active-only presence gate
       (getActiveByInitials) so a retired operator is blocked exactly like an
       unknown one (FAT-USR-090). checked is always True (the resolve ran), so
       the view can distinguish 'not yet typed' (its initial default
       checked=False) from 'typed but bad'."""
    BlueRidge.Common.Util.log("initials=%s" % initials)
    text = (initials or "").strip()
    if not text:
        return {"appUserId": None, "initials": "", "displayName": "",
                "valid": False, "checked": True}
    row = getActiveByInitials(text)
    if not row:
        return {"appUserId": None, "initials": text, "displayName": "",
                "valid": False, "checked": True}
    return {
        "appUserId":   row.get("Id"),
        "initials":    row.get("Initials") or text,
        "displayName": row.get("DisplayName") or "",
        "valid":       True,
        "checked":     True,
    }


# =============================================================================
# ELEVATION CREDENTIAL SOURCE -- SINGLE DEPLOYMENT KNOB (FDS-04-007)
#
# _ELEVATION_USER_SOURCE names the Ignition *user source* that per-action
# elevation challenges. Changing WHICH directory backs elevation is a one-line
# change here plus gateway configuration -- the API below does not change:
# system.security.validateUser is the correct call for every user source type,
# including Active Directory / AD Hybrid / AD-to-DB (an AD-typed source performs
# an LDAP bind against the domain controller inside the same call).
#
# *** CURRENT STATE (verified on the dev gateway 2026-08-19) ***
# The gateway has exactly three user sources -- 'default', 'MPP' and
# 'opcua-module' -- and ALL THREE are type INTERNAL. There is NO Active Directory
# user source configured, and the only Identity Provider ('default') is internal.
# So elevation authenticates today against the INTERNAL 'MPP' source, which is
# what makes dev/test elevation work at all.
#
# AT DEPLOYMENT: MPP IT creates the Active Directory user source on the gateway
# (Config > Security > Users, Roles -- domain, host(s), search base, binding
# service account), then this constant is repointed at that source's NAME. No
# other code changes. Do NOT repoint it at a name that does not exist on the
# gateway: validateUser then throws and EVERY elevation is denied (that is the
# exact failure mode fixed in aa2c5ded).
#
# Attribution/audit is independent of the source: validateUser only gates the
# password; the account name flows on to Location.AppUser_AuthenticateAd, which
# resolves it to an AppUser (Location.AppUser.AdAccount must match the directory
# account name) and writes the ElevationGranted / ElevationDenied audit row.
# =============================================================================
_ELEVATION_USER_SOURCE = "MPP"  # Name of a user source configured on the gateway
                                # (Config > Security > Users, Roles).
                                # "" = the project's default user source.


def _validateAdCredentials(adAccount, password):
    """Challenge a supervisor credential against _ELEVATION_USER_SOURCE
       (FDS-04-007).

       The password is checked HERE; the stored proc (AppUser_AuthenticateAd)
       receives only the account name and does the post-validation AppUser
       mapping + role resolution + audit -- so the elevating identity is still
       captured for auditing (validateUser returns only a boolean, but we pass
       the typed account on to the proc).

       See the banner above for which directory this currently resolves to and
       what has to change to point it at Active Directory.

       Returns a (validated, reason) tuple and NEVER raises -- any error degrades
       to (False, <reason>) so nothing silently authenticates."""
    account = (adAccount or "").strip()
    if not account or not password:
        return (False, "Enter both account and password.")
    try:
        ok = system.security.validateUser(account, password, _ELEVATION_USER_SOURCE)
    except Exception as e:
        # Almost always a user-source NAME that does not exist on this gateway.
        # Name it in both the log and the operator message so the misconfiguration
        # is self-diagnosing instead of presenting as "wrong password".
        BlueRidge.Common.Util.log(
            "validateUser error (userSource=%s account=%s): %s"
            % (_ELEVATION_USER_SOURCE, account, e), level="error")
        return (False, "Credential validation error - user source '%s' is not "
                       "configured on this gateway." % _ELEVATION_USER_SOURCE)
    if ok:
        return (True, "")
    return (False, "Invalid account or password.")


def elevate(adAccount, password, actionCode, terminalLocationId):
    """Per-action AD elevation for the Elevation Modal (FDS-04-007).

       1. Validate the AD credential via the gateway AD IdP seam
          (_validateAdCredentials). If it does not validate, return failure
          WITHOUT touching the proc (no audit row for an unvalidated credential).
       2. If validated, call authenticateAd (the proc does the role check vs
          actionCode AND writes the ElevationGranted / ElevationDenied audit row).

       No sticky session -- every protected action re-prompts. Returns
       {success, appUserId, message, ignitionRole}."""
    BlueRidge.Common.Util.log(
        "adAccount=%s actionCode=%s terminalLocationId=%s"
        % (adAccount, actionCode, terminalLocationId)
    )
    validated, reason = _validateAdCredentials(adAccount, password)
    if not validated:
        return {"success": False, "appUserId": None,
                "message": reason, "ignitionRole": None}
    res = authenticateAd(adAccount, actionCode, terminalLocationId)
    return {
        "success":      bool(res.get("Status")),
        "appUserId":    res.get("AppUserId"),
        "message":      res.get("Message"),
        "ignitionRole": res.get("IgnitionRole"),
    }


def logOperatorChange(oldAppUserId, newAppUserId, terminalLocationId=None, appUserId=None):
    """Audit a terminal operator handoff. Fired from InitialsEntry.loginAs on every sign-in
       path (typed / scanned / post-registration). Thin glue only: the SQL proc
       Audit.OperatorChange_Log resolves operator names + terminal code, builds the
       description + resolved-name JSON, suppresses a same-operator re-scan, and writes the
       Audit.OperationLog row. Attribution defaults to the NEW operator.

       Fire-and-forget: a logging failure must NEVER block an operator from signing in, so
       every error - including Java throwables that Jython's `except Exception` misses - is
       swallowed with a warning."""
    try:
        newId = BlueRidge.Common.Util.toIntOrNone(newAppUserId)
        if newId is None:
            return
        params = {
            "oldAppUserId":       BlueRidge.Common.Util.toIntOrNone(oldAppUserId),
            "newAppUserId":       newId,
            "terminalLocationId": BlueRidge.Common.Util.toIntOrNone(terminalLocationId),
            "appUserId":          BlueRidge.Common.Util.toIntOrNone(appUserId) or newId,
        }
        BlueRidge.Common.Db.execMutation("audit/OperatorChange_Log", params)
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("logOperatorChange failed (non-fatal): %s" % e, level="warn")
