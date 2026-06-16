"""BlueRidge.Location.AppUser - thin access to operator / AD auth procs.

   Wrappers only; no business logic."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def getUserList(includeDeprecated=False):
	"""
    Gets a list of user data.

    Args:
    	includeDeprecated (bool):   Whether or not the list should include deprecated users

    Returns:
        A list of objects of user data.
    """
	BlueRidge.Common.Util.log("includeDeprecated=%s" % includeDeprecated)
	return BlueRidge.Common.Db.execOne(
		"location/AppUser_List",
		{"includeDeprecated": includeDeprecated}
	)
	
def getUser(chosenId):
	"""
    Gets data from a user based on a chosen Id number.

    Args:
    	chosenId (int): the id of the user to read the data from.

    Returns:
        An object of a single user's data.
    """
	BlueRidge.Common.Util.log("id=%s" % chosenId)
	return BlueRidge.Common.Db.execOne(
		"location/AppUser_Get", 
		{"id": chosenId}
	)
	
def createUser(attributes):
	"""
    Creates a new user with dict "attributes".

    Args:
    	attributes (dict):	The attributes to be passed into the new user.
    	initials (string), displayName (string), adAccount (string),
    	ignitionRole (string), appUserId (string).
    	initials must be unique. If creating operator, then adAccount and
    	ignition role must be set to None.

    Returns:
        A message of whether the query succeeded or not.
    """
	BlueRidge.Common.Util.log("initials=%s" % attributes.get("Initials"))
	return BlueRidge.Common.Db.execOne("location/AppUser_Create", attributes)

def deprecateUser(chosenId, appUserId):
	"""
    Deprecates a user (soft delete, can be access later if needed)

    Args:
    	chosenId (int): the id of the user,
    	appUserId (int): the session id of the user (for audit logs)

    Returns:
        A message of whether the query succeeded or not.
    """
	BlueRidge.Common.Util.log("id=%s appUserId=%s" % (chosenId, appUserId))
	return BlueRidge.Common.Db.execOne(
		"location/AppUser_Deprecate", 
		{"id": chosenId, "appUserId": appUserId}
	)

def updateUser(attributes):
	"""
    Updates a new user with dict "attributes" using an id

    Args:
    	attributes (dict):	The attributes to be passed into the new user.
    	id (int),
    	initials (string), displayName (string), adAccount (string),
    	ignitionRole (string), appUserId (string).
    	initials must be unique. If creating operator, then adAccount and
    	ignition role must be set to None.

    Returns:
        A message of whether the query succeeded or not.
    """
	BlueRidge.Common.Util.log("initials=%s" % attributes.get("Initials"))
	return BlueRidge.Common.Db.execOne("location/AppUser_Update", attributes)


def getByInitials(initials):
    """Resolve an AppUser by shop-floor initials. Returns a dict or None."""
    BlueRidge.Common.Util.log("initials=%s" % initials)
    return BlueRidge.Common.Db.execOne(
        "location/AppUser_GetByInitials",
        {"initials": initials},
    )


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

       valid=False / displayName="" when the initials are blank or unrecognised.
       checked is always True (the resolve ran), so the view can distinguish
       'not yet typed' (its initial default checked=False) from 'typed but bad'."""
    BlueRidge.Common.Util.log("initials=%s" % initials)
    text = (initials or "").strip()
    if not text:
        return {"appUserId": None, "initials": "", "displayName": "",
                "valid": False, "checked": True}
    row = getByInitials(text)
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


def _validateAdCredentials(adAccount, password):
    """DEPLOYMENT-TIME INTEGRATION SEAM (FDS-04-007) -- NOT YET WIRED.

       Validates the AD *credential* (username + password) against the gateway's
       Active Directory Identity Provider. Per FDS-04-007 the password is checked
       by Ignition's AD IdP binding (system.security / IdP challenge), NOT by the
       stored proc (AppUser_AuthenticateAd receives only @AdAccount and performs
       the post-validation role check + audit). This function MUST be wired to the
       configured gateway AD identity provider at deployment.

       Returns a (validated, reason) tuple.

       SAFE DEFAULT: until the IdP federation is configured this returns
       (False, <reason>) so NOTHING silently authenticates. Do not replace this
       with a permissive stub -- the only correct change here is to call the real
       gateway AD challenge."""
    BlueRidge.Common.Util.log("adAccount=%s (AD credential validation seam)" % adAccount)
    return (False,
            "AD credential validation not yet wired - configure gateway AD "
            "identity provider (FDS-04-007)")


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
