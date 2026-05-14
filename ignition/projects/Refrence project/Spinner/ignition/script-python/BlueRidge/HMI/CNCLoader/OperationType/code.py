import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Logging helper for OperationType module.

	Args:
		msg (str): Message to log
	
	Returns:
		None
	"""
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)

def getOperationTypes():
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Retrieves all operation types from the database.

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
	Date: 07/07/2025
	Returns operation types formatted for dropdown/selectors.

	Returns:
		list[dict]
	"""
	log('running')
	operations = getOperationTypes()
	resp = [{
		"text": operation.get('name'),
		"view": operation.get('operationTypeUUID'),
		"value": "",
		"key": operation.get('operationTypeUUID')
	} for operation in operations]
	log('resp=%s' % (resp))
	return resp

def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Returns details for a single operation type by UUID.

	Args:
		data (str): UUID of the operation type

	Returns:
		dict
	"""
	log('data=%s' % (data))
	resp = {}
	if data or data != 0:
		operationTypes = getOperationTypes()
		for operationType in operationTypes:
			if str(operationType.get("operationTypeUUID")) == str(data):
				resp = {
					"name": operationType.get("name"),
					"selectionScreen": operationType.get("hmiView"),
					"notes": operationType.get('notes'),
					"available": operationType.get("active"),
					"key": operationType.get("operationTypeUUID"),
					"type": "operationType"
				}
	else:
		resp = {
			"name": '',
			"selectionScreen": '',
			"notes": '',
			"available": False,
			"key": '',
			"type": "operationType"
		}
	log('resp=%s' % (resp))
	return resp

def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Adds a new operation type with default placeholder values.

	Args:
		data (dict|str): Dict or JSON string with user field

	Returns:
		any
	"""
	log('data=%s' % (data))
	namedQuery = "recipe/addOperationType"
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	
	params = {
		'name': 'New OperationType',
		'hmiView': None,
		'notes': '',
		'active': False,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user'),
		'operationTypeUUID': None
	}
	resp = system.db.execQuery(namedQuery, params)
	log('resp=%s' % (resp))
	return resp

def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Updates an existing operation type.

	Args:
		data (dict|str): Dict or JSON string

	Returns:
		any
	"""
	log('data=%s' % (data))
	namedQuery = "recipe/addOperationType"
	if isinstance(data, str):
		data = system.util.jsonDecode(data)

	params = {
		'name': data.get('name'),
		'hmiView': data.get('selectionScreen'),
		'notes': data.get('notes'),
		'active': data.get('available'),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user'),
		'operationTypeUUID': data.get('key')
	}
	resp = system.db.execQuery(namedQuery, params)
	log('resp=%s' % (resp))
	return resp

def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Archives (deletes) an operation type by UUID or dict with key.

	Args:
		data (str|dict): UUID or dict

	Returns:
		any
	"""
	log('data=%s' % (data))
	namedQuery = "recipe/deleteOperationType"
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	UUID = data.get('key') if isinstance(data, dict) else data
	params = {'UUID': UUID}
	resp = system.db.execQuery(namedQuery, params)
	log('resp=%s' % (resp))
	return resp