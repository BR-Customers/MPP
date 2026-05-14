import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Helper function for consistent logging with function tracing.
	
	Args:
		msg (str): message to log
		
	Returns:
		None
	"""
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)

def getHeads():
	"""
	Author: Hunter Kraft
	Date: 12/10/2025
	Retrieves heads from the config/getHeads named query.
	
	Returns:
		list[dict]
	"""
	namedQuery = "config/getHeads"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	return resp

def getHeadConfigs(uuid):
	"""
	Author: Hunter Kraft
	Date: 12/10/2025
	Retrieves head configs from the config/getHeadConfigs named query.
	
	Returns:
		list[dict]
	"""
	namedQuery = "config/getHeadConfigs"
	results = system.db.execQuery(namedQuery, parameters = {'headUUID':uuid})
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	return resp

def getOneHeadConfig(uuid):
	
	namedQuery = 'config/getHeadConfig'
	results = system.db.execQuery(namedQuery, parameters = {'headConfigUUID': uuid})
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	return resp

def getAvailableConfigs():
	"""
	Author: Jennifer Lewis
	Date: 02/05/2026
	Retrieves active/available head configs from the config/getHeadConfigs named query.
	
	Returns:
		list[dict]
	"""
	results = system.db.execQuery("config/getAllConfigs")
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	configs = []
	for head in resp:
		configs.append({
			"text": head.get('name', ''),
			"view": head.get('headConfigUUID', ''),
			"value": head.get('headConfigUUID', ''),
			"key": head.get('headConfigUUID', ''),
			"available": head.get("active", False),
			"label": head.get('name', '')
		})
	return configs

def getHeadFiles(uuid):
	"""
	Author: Hunter Kraft
	Date: 12/10/2025
	Retrieves head files from the config/getHeadFiles named query.
	
	Returns:
		list[dict]
	"""
	namedQuery = "config/getHeadFiles"
	results = system.db.execQuery(namedQuery, parameters = {'headConfigUUID':uuid})
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	return resp

def getHeadFileByUUID(uuid):
	"""
	Author: Hunter Kraft
	Date: 12/10/2025
	Retrieves head configs from the config/getHeadConfigs named query.
	
	Returns:
		list[dict]
	"""
	namedQuery = "config/getHeadFileByUUID"
	results = system.db.execQuery(namedQuery, parameters = {'headFileUUID':uuid})
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	return resp

def getAll():
	"""
	Author: Hunter Kraft
	Date: 12/10/2025
	Returns head configurations formatted for UI selectors.
	
	Returns:
		list[dict]
	"""

	heads = getHeads()
	resp = []
	for head in heads:
		resp.append({
			"text": head.get('name', ''),
			"view": head.get('headUUID', ''),
			"value": "",
			"key": head.get('headUUID', ''),
			"available": head.get("active", False)
		})

	return resp

def getOne(data):
	"""
	Author: Hunter Kraft
	Date: 07/03/2025
	Returns details about a specific head's configurations given its UUID.
	
	Args:
		data (str): UUID of the head
		
	Returns:
		dict
	"""
	heads = getHeads()
	head = {}
	for row in heads:
		if row.get('headUUID','') == data:
			head = row
	if data:
		configs = getHeadConfigs(data)
		resp = {
			"name": head.get('name',''),
			"aspectRatio" : head.get('aspectRatio',''),
			"available": head.get("active", False),
			"extensionTypeUUID": head.get("extensionTypeUUID", ''),
			"configs": configs 
		}
	
	return resp
	
def addHeadGroup(data):
	"""
	Author: Hunter Kraft
	Date: 07/03/2025
	Adds a new head group with default placeholder values.
	
	Args:
		data (dict|str): JSON string or dict with user field
		
	Returns:
		any - result of named query
	"""

	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	params = {
		'name': 'New Head Group',
		'active': False,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'headUUID': None,
		'extensionTypeUUID': None
	}
	resp = system.db.execUpdate("config/addHead", params)
	
	return resp
	
def addHeadConfig(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025 (Revised 01/28/2026)
	Adds a new head configuration with default placeholder values.
	
	Args:
		data (dict|str): JSON string or dict with user and headUUID field
		
	Returns:
		any - result of named query
	"""
	
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	params = {
		'name': 'New Head Config',
		'active': False,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'headUUID': data.get('headUUID', ''),
		'headConfigUUID': None
	}
	resp = system.db.execUpdate("config/addHeadConfig", params)
	
	return resp

def addHeadFile(data):
	"""
	Author: Jennifer Lewis
	Date: 01/28/2026
	Adds a new image to the database for a head config.
	
	Args:
		data (dict|str): JSON string or dict with user, headConfigUUID, fileType, fileName, and fileData field
		
	Returns:
		any - result of named query
	"""
	
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	params = {
		'fileName': data.get('fileName', ''),
		'fileData': data.get('fileData', ''),
		'fileType': data.get('fileType', ''),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'headConfigUUID': data.get('headConfigUUID', ''),
		'headFileUUID': None
	}
	resp = system.db.execUpdate("config/addHeadFile", params)
	
	return resp

def updateHeadGroup(data):
	"""
	Author: Jennifer Lewis
	Date: 01/28/2026
	Updates an existing head group with the new name and active status.
	
	Args:
		data (dict|str): JSON string or dict with user, headUUID, name, and active field
		
	Returns:
		any - result of named query
	"""
	
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	params = {
		'name': data.get('name', ''),
		'active': data.get('active', ''),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'headUUID': data.get('headUUID', ''),
		'extensionTypeUUID': data.get('extensionTypeUUID', None)
	}
	resp = system.db.execUpdate("config/addHead", params)
	
	return resp

def updateHeadConfig(data):
	"""
	Author: Jennifer Lewis
	Date: 01/28/2026
	Updates an existing head configuration with new values.
	
	Args:
		data (dict|str): JSON string or dict with user, headUUID, headConfigUUID, name, and active field
		
	Returns:
		any - result of named query
	"""
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	params = {
		'name': data.get('name', ''),
		'active': data.get('active', ''),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'headUUID': data.get('headUUID', ''),
		'headConfigUUID': data.get('headConfigUUID', '')
	}
	resp = system.db.execUpdate("config/addHeadConfig", params)
	
	return resp

def updateHeadFile(data):
	"""
	Author: Jennifer Lewis
	Date: 01/28/2026
	Updates an image for a head config.
	
	Args:
		data (dict|str): JSON string or dict with user, headConfigUUID, headfileUUID, fileType, fileName, and fileData field
		
	Returns:
		any - result of named query
	"""
	
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	params = {
		'fileName': data.get('fileName', ''),
		'fileData': data.get('fileData', ''),
		'fileType': data.get('fileType', ''),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'headConfigUUID': data.get('headConfigUUID', ''),
		'headFileUUID': data.get('headFileUUID', '')
	}
	resp = system.db.execUpdate("config/addHeadFile", params)
	
	return resp

def deleteHeadGroup(data):
	"""
	Author: Jennifer Lewis
	Date: 01/27/2026
	Deletes a head group and cascade-deletes further linked objects.
	
	Args:
		data (str): The UUID of the head group to be deleted
		
	Returns:
		any - result of named query
	"""
	
		
	params = {'UUID': str(data)}
	system.db.execUpdate("config/deleteHead", params)
	
	configsToDelete = getHeadConfigs(str(data))
	for config in configsToDelete:
		deleteHeadConfig(config['headConfigUUID'])
	
	return "head deleted"

def deleteHeadConfig(data):
	"""
	Author: Jennifer Lewis
	Date: 01/28/2026
	Deletes a head config.
	
	Args:
		data (str): The UUID of the head config to be deleted
		
	Returns:
		any - result of named query
	"""
	
		
	params = {'UUID': str(data)}
	system.db.execUpdate("config/deleteHeadConfig", params)
	
	filesToDelete = getHeadFiles(str(data))
	for headFile in filesToDelete:
		deleteHeadFile(headFile['headFileUUID'])
	
	operationsToDelete = getAllHeadOperations(str(data))
	for operation in operationsToDelete:
		deleteHeadOperation(operation['headOperationUUID'])
	
	pairsToDelete = BlueRidge.Recipe.OperationHead.getOperationByHead(str(data))
	for pair in pairsToDelete:
		BlueRidge.Recipe.OperationHead.archive(pair['headOperationUUID'])
	
	return "head config deleted"

def deleteHeadFile(data):
	"""
	Author: Jennifer Lewis
	Date: 01/28/2026
	Deletes a head config file.
	
	Args:
		data (str): The UUID of the head config to be deleted
		
	Returns:
		any - result of named query
	"""
	
		
	params = {'UUID': str(data)}
	system.db.execUpdate("config/deleteHeadFile", params)
	return "head deleted"


def getHeadOperations(uuid, opType):
    """
    Author: Jennifer Lewis (modified)
    Date: 02/02/2026
    Retrieves head operations from the config/getHeadOperations named query.
    Decodes the 'widgets' JSON string into a Python list/dict.
    """
    logger = system.util.getLogger("getHeadOperations")

    namedQuery = "config/getHeadOperations"
    results = system.db.execQuery(namedQuery, parameters={'headConfigUUID': uuid, 'operationTypeUUID': opType})
    headers = list(results.getColumnNames())

    resp = [dict(zip(headers, row)) for row in results]

    for i in range(len(resp)):
        w = resp[i].get('widgets', None)

        # Decode if it is JSON text
        if w not in (None, ''):
            try:
                # In Ignition/Jython, JSON text is typically a basestring
                if isinstance(w, basestring):
                    decoded = system.util.jsonDecode(w)
                    resp[i]['widgets'] = decoded
                else:
                    # Already decoded or non-string; keep it
                    resp[i]['widgets'] = w

            except Exception as ex:
                logger.warn("Failed to decode widgets for row %d. Leaving as-is. Error=%s" % (i, ex))

    return resp

def getAllHeadOperations(uuid):
    """
    Author: Jennifer Lewis (modified)
    Date: 02/02/2026
    Retrieves head operations from the config/getAllHeadOperations named query.
    Decodes the 'widgets' JSON string into a Python list/dict.
    """
    logger = system.util.getLogger("getHeadOperations")

    namedQuery = "config/getAllHeadOperations"
    results = system.db.execQuery(namedQuery, parameters={'headConfigUUID': uuid})
    headers = list(results.getColumnNames())

    resp = [dict(zip(headers, row)) for row in results]

    for i in range(len(resp)):
        w = resp[i].get('widgets', None)

        # Decode if it is JSON text
        if w not in (None, ''):
            try:
                # In Ignition/Jython, JSON text is typically a basestring
                if isinstance(w, basestring):
                    decoded = system.util.jsonDecode(w)
                    resp[i]['widgets'] = decoded
                else:
                    # Already decoded or non-string; keep it
                    resp[i]['widgets'] = w

            except Exception as ex:
                logger.warn("Failed to decode widgets for row %d. Leaving as-is. Error=%s" % (i, ex))

    return resp

def getHeadOperation(uuid):
    """
    Author: Hunter Kraft
    Date: 02/11/2026
    Retrieves head operation from the config/getHeadOperation named query.
    Decodes the 'widgets' JSON string into a Python list/dict.
    """
    logger = system.util.getLogger("getHeadOperations")

    namedQuery = "config/getHeadOperation"
    results = system.db.execQuery(namedQuery, parameters={'headOperationUUID': uuid})
    headers = list(results.getColumnNames())

    resp = [dict(zip(headers, row)) for row in results]

    for i in range(len(resp)):
        w = resp[i].get('widgets', None)

        # Decode if it is JSON text
        if w not in (None, ''):
            try:
                # In Ignition/Jython, JSON text is typically a basestring
                if isinstance(w, basestring):
                    decoded = system.util.jsonDecode(w)
                    resp[i]['widgets'] = decoded
                else:
                    # Already decoded or non-string; keep it
                    resp[i]['widgets'] = w

            except Exception as ex:
                logger.warn("Failed to decode widgets for row %d. Leaving as-is. Error=%s" % (i, ex))

    return resp

def addHeadOperation(data):
	"""
	Author: Jennifer Lewis
	Date: 02/02/2026
	Adds a new head operation with default placeholder values.
	
	Args:
		data (dict|str): JSON string or dict with user and headUUID field
		
	Returns:
		any - result of named query
	"""
	
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	params = {
		'name': 'New Head Operation',
		'active': False,
		'multiSelectable': False,
		'widgets': None,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'headFileUUID': data.get('headFileUUID', ''),
		'headConfigUUID': data.get('headConfigUUID', ''),
		'operationTypeUUID': data.get('operationTypeUUID', ''),
		'headOperationUUID': None
	}
	resp = system.db.execUpdate("config/addHeadOperation", params)
	
	return resp

def updateHeadOperation(data):
	"""
	Author: Jennifer Lewis
	Date: 02/02/2026
	Updates a head operation with input values.
	
	Args:
		data (dict|str): JSON string or dict with user and headUUID field
		
	Returns:
		any - result of named query
	"""
	
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	params = {
		'name': data.get('name', ''),
		'active': data.get('active', ''),
		'multiSelectable': data.get('multiSelectable', ''),
		'widgets': system.util.jsonEncode(data.get('widgets', '')),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'headFileUUID': data.get('headFileUUID', ''),
		'headConfigUUID': data.get('headConfigUUID', ''),
		'operationTypeUUID': data.get('operationTypeUUID', ''),
		'headOperationUUID': data.get('headOperationUUID', '')
	}
	resp = system.db.execUpdate("config/addHeadOperation", params)
	
	return resp

def deleteHeadOperation(data):
	"""
	Author: Jennifer Lewis
	Date: 01/27/2026
	Deletes a head operation.
	
	Args:
		data (str): The UUID of the head operation to be deleted
		
	Returns:
		any - result of named query
	"""
	
	
	params = {'UUID': str(data)}
	system.db.execUpdate("config/deleteHeadOperation", params)
	return "head deleted"