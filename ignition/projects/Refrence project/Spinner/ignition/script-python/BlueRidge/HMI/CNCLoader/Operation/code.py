import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Logging helper for consistent format.
	
	Args:
		msg (str): Message to log
	
	Returns:
		None
	"""
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)

def getOperations():
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Runs named query to fetch all operations.
	
	Returns:
		list[dict]
	"""
	namedQuery = "recipe/getOperations"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	return resp

def getAll(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Returns all operations filtered by operationTypeUUID.
	
	Args:
		data (str): operationTypeUUID
	
	Returns:
		list[dict]
	"""
	log('data=%s' % (data))
	operations = getOperations()
	resp = []
	for operation in operations:
		resp.append({
			"text": operation.get('name'),
			"view": operation.get('operationUUID'),
			"value": "",
			"key": operation.get('operationUUID'),
			"type": operation.get('operationTypeUUID'),
			"messageType": "OneShotButtonOperation"
		})
	if data:
		resp = [op for op in resp if op.get("type") == data]
	log('resp=%s' % (resp))
	return resp

def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Returns operation details by UUID.
	
	Args:
		data (str): operationUUID
	
	Returns:
		dict
	"""
	log('data=%s' % (data))
	resp = {
		"name": '',
		"available": False,
		"key": '',
		"type": None,
		"engines": []
	}
	if data:
		operations = getOperations()
		for operation in operations:
			if str(operation.get("operationUUID")) == str(data):
				resp = {
					"name": operation.get("name"),
					"available": operation.get("active"),
					"key": operation.get("operationUUID"),
					"type": operation.get("operationTypeUUID"),
					"engines": []
				}
				break
	log('resp=%s' % (resp))
	return resp