import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Logging helper for OperationEngine module.
	
	Args:
		msg (str): message to log
	
	Returns:
		None
	"""
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)

def getOperationEngines():
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Fetch all operation-engine mappings from the database.
	
	Returns:
		list[dict]
	"""
	namedQuery = "recipe/getEngineOperations"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	return resp

def getAll(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Returns all engine mappings for a given operation UUID.
	
	Args:
		data (str): operationUUID
	
	Returns:
		list[dict]
	"""
	log('data=%s' % (data))
	operationEngines = getOperationEngines()
	resp = []
	for operationEngine in operationEngines:
		if operationEngine.get('operationUUID') == data:
			engine = BlueRidge.HMI.CNCLoader.Engine.getOne(operationEngine.get('engineUUID'))
			resp.append({
				"text": engine.get('name'),
				"view": operationEngine.get('engineOperationUUID'),
				"value": "",
				"key": operationEngine.get('engineOperationUUID'),
				"messageType": "OneShotButton"
			})
	log('resp=%s' % (resp))
	return resp

def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Returns details about an engine-operation mapping.
	
	Args:
		data (str): engineOperationUUID
	
	Returns:
		dict
	"""
	log('data=%s' % (data))
	operationEngines = getOperationEngines()
	resp = {}
	for operationEngine in operationEngines:
		if operationEngine.get('engineOperationUUID') == data:
			engine = BlueRidge.HMI.CNCLoader.Engine.getOne(operationEngine.get('engineUUID'))
			resp = {
				"text": engine.get('name'),
				"key": operationEngine.get('engineOperationUUID'),
				"engineUUID": operationEngine.get("engineUUID"),
				"operationUUID": operationEngine.get('operationUUID'),
			}
	log('resp=%s' % (resp))
	return resp

def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Adds a new engine-operation mapping.
	
	Args:
		data (dict|str): input data
	
	Returns:
		any
	"""
	log('data=%s' % (data))
	namedQuery = "recipe/addEngineOperation"
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	params = {
		'operationUUID': data.get('operationUUID'),
		'engineUUID': data.get('engineUUID')
	}
	resp = system.db.execQuery(namedQuery, params)
	log('resp=%s' % (resp))
	return resp

def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Currently not implemented for engine-operation updates.
	
	Args:
		data (any): any input
	
	Returns:
		str
	"""
	log('data=%s' % (data))
	return 'success'

def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Archives an engine-operation mapping by UUID or dict.
	
	Args:
		data (str|dict): UUID or dict with key
	
	Returns:
		any
	"""
	log('data=%s' % (data))
	namedQuery = "recipe/deleteEngineOperation"
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	UUID = data.get('key') if isinstance(data, dict) else data
	params = {'UUID': UUID}
	resp = system.db.execQuery(namedQuery, params)
	log('resp=%s' % (resp))
	return resp