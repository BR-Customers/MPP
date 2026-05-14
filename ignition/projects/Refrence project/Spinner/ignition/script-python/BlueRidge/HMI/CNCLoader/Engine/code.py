import inspect

def log(msg):
    """
    Author: Ronald Pulliam
    Date: 07/07/2025
    Consistent logging helper with function tracing.

    Args:
        msg (str): message to log

    Returns:
        None
    """
    BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getEngines():
    """
    Author: Ronald Pulliam
    Date: 07/07/2025
    Retrieves engine records from the config/getEngines named query.

    Returns:
        list[dict]
    """
    namedQuery = "config/getEngines"
    results = system.db.execQuery(namedQuery)
    headers = list(results.getColumnNames())
    return [dict(zip(headers, row)) for row in results]


def getAll():
    """
    Author: Ronald Pulliam
    Date: 07/07/2025
    Returns engines formatted for UI selectors.

    Returns:
        list[dict]
    """
    log("running")
    engines = getEngines()
    resp = []
    for engine in engines:
        resp.append({
            "text": engine.get("name", ""),
            "view": engine.get("engineUUID"),
            "value": "",
            "key": engine.get("engineUUID"),
            "available": engine.get("active", False),
        })
    log("resp=%s" % (resp))
    return resp


def getOne(data):
    """
    Author: Ronald Pulliam
    Date: 07/07/2025
    Retrieves details for a specific engine UUID.

    Args:
        data (str): UUID

    Returns:
        dict
    """
    log("data=%s" % (data))
    resp = {
        "name": "",
        "available": False,
        "key": "",
        "blockConfig": "",
    }
    if data:
        engines = getEngines()
        for engine in engines:
            if str(engine.get("engineUUID")) == str(data):
                resp = {
                    "name": engine.get("name", ""),
                    "available": engine.get("active", False),
                    "key": engine.get("engineUUID"),
                    "blockConfig": engine.get("blockConfig"),
                }
                break
    log("resp=%s" % (resp))
    return resp


def add(data):
    """
    Author: Ronald Pulliam
    Date: 07/07/2025
    Adds a new engine with default placeholder values.

    Args:
        data (dict|str): JSON string or dict with 'user' field

    Returns:
        any - result of named query
    """
    log("data=%s" % (data))
    if isinstance(data, str):
        data = system.util.jsonDecode(data)

    params = {
        "engineUUID": None,
        "plantUUID": None,
        "name": "New Engine",
        "active": False,
        "lastEdited": system.date.now(),
        "lastEditedBy": data.get("user"),
        "blockConfig": None
    }
    resp = system.db.execQuery("config/addEngine", params)
    log("resp=%s" % (resp))
    return resp


def update(data):
    """
    Author: Ronald Pulliam
    Date: 07/07/2025
    Updates an existing engine record.

    Args:
        data (dict|str): JSON string or dict

    Returns:
        any - result of named query
    """
    log("data=%s" % (data))
    if isinstance(data, str):
        data = system.util.jsonDecode(data)

    params = {
        "engineUUID": data.get("key"),
        "plantUUID": data.get("plantUUID"),
        "name": data.get("name"),
        "active": data.get("available", False),
        "lastEdited": system.date.now(),
        "lastEditedBy": data.get("user"),
        "blockConfig": data.get("blockConfig")
    }
    resp = system.db.execQuery("config/addEngine", params)
    log("resp=%s" % (resp))
    return resp


def archive(data):
    """
    Author: Ronald Pulliam
    Date: 07/07/2025
    Archives (deletes) an engine by UUID.

    Args:
        data (str|dict): JSON string, UUID, or dict

    Returns:
        any - result of named query
    """
    log("data=%s" % (data))
    if isinstance(data, str):
        data = system.util.jsonDecode(data)

    UUID = data
    if isinstance(data, dict):
        UUID = data.get("key")

    params = {"UUID": UUID}
    resp = system.db.execQuery("config/deleteEngine", params)
    log("resp=%s" % (resp))
    return resp