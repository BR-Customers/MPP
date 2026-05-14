import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Helper function for standardized project logging with automatic
	caller function name detection.
	
	Args:
		msg (str): message to log
		
	Returns:
		None
	"""
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getOperationTypes():
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Runs recipe/getOperationTypes named query and returns the results as list[dict].
	
	Returns:
		list[dict]
	"""
	namedQuery = "recipe/getOperationTypes"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	return resp


def getAll():
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Returns a list of operation types formatted for UI selectors.
	
	Returns:
		list[dict]
	"""
	log('running')
	operations = getOperationTypes()
	resp = []
	for operation in operations:
		resp.append({
			"text": operation.get('name', ''),
			"view": operation.get('operationTypeUUID', ''),
			"value": "",
			"key": operation.get('operationTypeUUID', ''),
			"available": operation.get("active", False),
		})
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Looks up a single operation type by UUID and returns details.
	
	Args:
		data (str): UUID
		
	Returns:
		dict
	"""
	log('data=%s' % (data))
	resp = {
		"name": '',
		"selectionScreen": '',
		"notes": '',
		"available": False,
		"key": '',
		"type": "operationType"
	}
	
	if data:
		operationTypes = getOperationTypes()
		for operationType in operationTypes:
			if str(operationType.get("operationTypeUUID")) == str(data):
				resp = {
					"name": operationType.get("name", ''),
					"selectionScreen": operationType.get("hmiView", ''),
					"notes": operationType.get('notes', ''),
					"available": operationType.get("active", False),
					"key": operationType.get("operationTypeUUID", ''),
					"type": "operationType",
				}
				break
	
	log('resp=%s' % (resp))
	return resp


def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Adds a new operation type with default placeholder values.
	
	Args:
		data (dict|str): JSON string or dict with user details
		
	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	params = {
		'name': 'New OperationType',
		'hmiView': None,
		'notes': '',
		'active': False,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'operationTypeUUID': None
	}
	resp = system.db.execQuery("recipe/addOperationType", params)
	log('resp=%s' % (resp))
	return resp


def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Archives (soft deletes) an operation type by UUID or dict with key.
	
	Args:
		data (str|dict): JSON string, UUID, or dict
		
	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	UUID = data
	if isinstance(data, dict):
		UUID = data.get('key')
	params = {'UUID': UUID}
	resp = system.db.execQuery("recipe/deleteOperationType", params)
	log('resp=%s' % (resp))
	return resp


def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Updates an existing operation type.
	
	Args:
		data (dict|str): JSON string or dict
		
	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	params = {
		'name': data.get('name', ''),
		'hmiView': data.get('selectionScreen', ''),
		'notes': data.get('notes', ''),
		'active': data.get('available', False),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'operationTypeUUID': data.get('key', '')
	}
	resp = system.db.execQuery("recipe/addOperationType", params)
	log('resp=%s' % (resp))
	return resp