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


def getOperationHeads():
	"""
	Author: Jennifer Lewis
	Date: 02/05/2026 
	Runs named query to retrieve all head-operation pairs.
	
	Returns:
		list[dict]
	"""
	log('running')
	namedQuery = "recipe/getHeadOperations"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	log('resp=%s' % (resp))
	return resp

def getOperationByHead(uuid):
	"""
	Author: Jennifer Lewis
	Date: 02/10/2026 
	Runs named query to retrieve all head-operation pairs and filters by the headUUID provided.
	
	Returns:
		list[dict]
	"""
	namedQuery = "recipe/getHeadOperations"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	finalList = []
	for operation in resp:
		if operation.get('headUUID') == uuid:
			finalList.append(operation)
	
	log('resp=%s' % (resp))
	return finalList


def getAll(data):
	"""
	Author: Jennifer Lewis 
	Date: 02/05/2026 
	Returns all heads assigned to a given operation.
	
	Args:
		data (str): operationUUID
		
	Returns:
		list[dict]
	"""
	log('data=%s' % (data))
	operationHeads = getOperationHeads()
	resp = []
	
	for oe in operationHeads:
		if oe.get('operationUUID') == data:
			head = BlueRidge.Recipe.Head.getOne(oe.get('headUUID'))
			resp.append({
				"text": head.get('name'),
				"view": oe.get('headOperationUUID'),
				"value": "",
				"key": oe.get('headOperationUUID'),
				"messageType": "OneShotButton"
			})
			
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Jennifer Lewis 
	Date: 02/05/2026 
	Returns a single head-operation link by UUID.
	
	Args:
		data (str): headOperationUUID
		
	Returns:
		dict
	"""
	log('data=%s' % (data))
	operationHeads = getOperationHeads()
	resp = {}
	
	for oe in operationHeads:
		if oe.get('headOperationUUID') == data:
			head = BlueRidge.Recipe.Head.getOne(oe.get('headUUID'))
			resp = {
				"text": head.get('name'),
				"key": oe.get('headOperationUUID'),
				"headUUID": oe.get('headUUID'),
				"operationUUID": oe.get('operationUUID')
			}
			break
			
	log('resp=%s' % (resp))
	return resp


def add(data):
	"""
	Author: Jennifer Lewis 
	Date: 02/05/2026
	Adds a head-operation link.
	
	Args:
		data (dict or str): data with headUUID and operationUUID
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	params = {
		'headUUID': data.get('headUUID'),
		'operationUUID': data.get('operationUUID')
	}
	namedQuery = "recipe/addHeadOperation"
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
	Author: Jennifer lewis
	Date: 02/09/2026 
	Deletes a head-operation link by UUID.
	
	Args:
		data (str or dict): headOperationUUID or dict with key
		
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
	namedQuery = "recipe/deleteHeadOperation"
	resp = system.db.execUpdate(namedQuery, params)
	
#	routinesToDelete = BlueRidge.Recipe.ParameterList.getAll(UUID)
#	for routine in routinesToDelete:
#		BlueRidge.Recipe.ParameterList.archive(routine['key'])
	
	log('resp=%s' % (resp))
	return resp