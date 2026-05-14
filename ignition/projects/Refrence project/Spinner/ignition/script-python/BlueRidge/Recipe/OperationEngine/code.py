import inspect

def log(msg):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Local logging wrapper for Recipe operations.
	
	Args:
		msg (str): Message to log
	
	Returns:
		None
	"""
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getOperationEngines():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Runs named query to retrieve all engine-operation pairs.
	
	Returns:
		list[dict]
	"""
	log('running')
	namedQuery = "recipe/getEngineOperations"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	log('resp=%s' % (resp))
	return resp


def getAll(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Returns all engines assigned to a given operation.
	
	Args:
		data (str): operationUUID
		
	Returns:
		list[dict]
	"""
	log('data=%s' % (data))
	operationEngines = getOperationEngines()
	resp = []
	
	for oe in operationEngines:
		if oe.get('operationUUID') == data:
			engine = BlueRidge.Recipe.Engine.getOne(oe.get('engineUUID'))
			resp.append({
				"text": engine.get('name'),
				"view": oe.get('engineOperationUUID'),
				"value": "",
				"key": oe.get('engineOperationUUID'),
				"messageType": "OneShotButton"
			})
			
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Returns a single engine-operation link by UUID.
	
	Args:
		data (str): engineOperationUUID
		
	Returns:
		dict
	"""
	log('data=%s' % (data))
	operationEngines = getOperationEngines()
	resp = {}
	
	for oe in operationEngines:
		if oe.get('engineOperationUUID') == data:
			engine = BlueRidge.Recipe.Engine.getOne(oe.get('engineUUID'))
			resp = {
				"text": engine.get('name'),
				"key": oe.get('engineOperationUUID'),
				"engineUUID": oe.get('engineUUID'),
				"operationUUID": oe.get('operationUUID')
			}
			break
			
	log('resp=%s' % (resp))
	return resp


def add(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Adds an engine-operation link.
	
	Args:
		data (dict or str): data with engineUUID and operationUUID
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	params = {
		'engineUUID': data.get('engineUUID'),
		'operationUUID': data.get('operationUUID')
	}
	namedQuery = "recipe/addEngineOperation"
	resp = system.db.execUpdate(namedQuery, params)
	log('resp=%s' % (resp))
	return resp


def update(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Stub for future update functionality.
	
	Args:
		data (any)
		
	Returns:
		str
	"""
	log('data=%s' % (data))
	return 'success'


def archive(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Deletes an engine-operation link by UUID.
	
	Args:
		data (str or dict): engineOperationUUID or dict with key
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	UUID = data
	if isinstance(data, dict):
		UUID = data.get('key')
		
	params = {'UUID': UUID}
	namedQuery = "recipe/deleteEngineOperation"
	resp = system.db.execQuery(namedQuery, params)
	log('resp=%s' % (resp))
	return resp