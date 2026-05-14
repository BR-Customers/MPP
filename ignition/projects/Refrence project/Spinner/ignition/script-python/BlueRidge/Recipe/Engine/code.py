import inspect

def log(msg):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Local project logger that routes to the BlueRidge logger.
	
	Args:
		msg (str): Message to log
		
	Returns:
		None
	"""
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getEngines():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Runs the named query to get all engines.
	
	Returns:
		list[dict]
	"""
	log('running')
	namedQuery = "config/getEngines"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	log('resp=%s' % (resp))
	return resp


def getAll():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Returns a list of engines formatted for dropdown or list components.
	
	Returns:
		list[dict]
	"""
	log('running')
	engines = getEngines()
	resp = []
	for engine in engines:
		resp.append({
			"text": engine.get('name'),
			"view": engine.get('engineUUID'),
			"value": "",
			"key": engine.get('engineUUID'),
			"available": engine.get('active'),
		})
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Returns a single engine record by engine UUID.
	
	Args:
		data (str): engine UUID
		
	Returns:
		dict
	"""
	log('data=%s' % (data))
	resp = {
		"name": None,
		"available": False,
		"key": None,
		"blockConfig": None
	}
	if data or data != 0:
		engines = getEngines()
		for engine in engines:
			if engine.get('engineUUID') == data:
				resp = {
					"name": engine.get("name"),
					"available": engine.get("active"),
					"key": engine.get("engineUUID"),
					"blockConfig": engine.get("blockConfig"),
					"type": "Engine"
				}
				break
	log('resp=%s' % (resp))
	return resp


def add(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Adds a new engine with default placeholder values.
	
	Args:
		data (dict or str): payload
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if type(data) == str:
		data = system.util.jsonDecode(data)
		
	namedQuery = "config/addEngine"
	params = {
		'engineUUID': None,
		'plantUUID': None,
		'name': 'New Engine',
		'active': False,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user')
	}
	resp = system.db.execQuery(namedQuery, params)
	log('resp=%s' % (resp))
	return resp


def archive(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Archives (soft deletes) an engine by UUID.
	
	Args:
		data (dict or str): engine UUID or JSON with key
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	namedQuery = "config/deleteEngine"
	if type(data) == str:
		data = system.util.jsonDecode(data)
		
	UUID = data
	if isinstance(data, dict):
		UUID = data.get('key')
		
	params = {'UUID': UUID}
	resp = system.db.execQuery(namedQuery, params)
	log('resp=%s' % (resp))
	return resp


def update(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Updates an existing engine.
	
	Args:
		data (dict or str): engine data
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if type(data) == str:
		data = system.util.jsonDecode(data)
		
	namedQuery = "config/addEngine"
	params = {
		'engineUUID': data.get('key'),
		'plantUUID': data.get('plantUUID'),
		'name': data.get('name'),
		'active': data.get('available'),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user')
	}
	resp = system.db.execQuery(namedQuery, params)
	log('resp=%s' % (resp))
	return resp