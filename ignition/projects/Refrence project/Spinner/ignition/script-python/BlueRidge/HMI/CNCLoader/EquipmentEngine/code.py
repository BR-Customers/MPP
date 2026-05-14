import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Helper function for consistent logging with function tracing.
	
	Args:
		msg (str): Message to log
		
	Returns:
		None
	"""
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)

def getEquipmentEngines():
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Retrieves all equipment-engine links from the named query.
	
	Returns:
		list[dict]
	"""
	namedQuery = "config/getEquipmentEngines"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	return resp

def getAll(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Returns all active engine associations for a given equipment UUID.
	
	Args:
		data (str): equipmentUUID
		
	Returns:
		list[dict]
	"""
	log('data=%s' % (data))
	equipmentEngines = getEquipmentEngines()
	resp = []
	for equipmentEngine in equipmentEngines:
		if equipmentEngine.get('equipmentUUID') == data:
			engine = BlueRidge.HMI.CNCLoader.Engine.getOne(equipmentEngine.get('engineUUID'))
			if engine.get('available'):
				resp.append({
					"text": engine.get('name'),
					"view": equipmentEngine.get('equipmentEngineUUID'),
					"value": "",
					"key": equipmentEngine.get('equipmentEngineUUID'),
					"equipmentUUID": equipmentEngine.get('equipmentUUID'),
					"engineUUID": equipmentEngine.get('engineUUID'),
				})
	log('resp=%s' % (resp))
	return resp

def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Retrieves one equipment-engine mapping by its UUID.
	
	Args:
		data (str): equipmentEngineUUID
		
	Returns:
		dict
	"""
	log('data=%s' % (data))
	resp = {}
	if data:
		for equipmentEngine in getEquipmentEngines():
			if equipmentEngine.get('equipmentEngineUUID') == data:
				resp = equipmentEngine
				break
	log('resp=%s' % (resp))
	return resp

def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Adds a new equipment-engine association.
	
	Args:
		data (dict|str): Equipment and engine UUIDs and user
		
	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)

	params = {
		'equipmentEngineUUID': None,
		'equipmentUUID': data.get('equipmentUUID'),
		'engineUUID': data.get('engineUUID'),
		'active': False,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user')
	}
	resp = system.db.execQuery("config/addEquipmentEngine", params)
	log('resp=%s' % (resp))
	return resp

def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Updates an equipment-engine association.
	
	Args:
		data (dict|str): Updated details of the association
		
	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)

	params = {
		'equipmentEngineUUID': data.get('equipmentEngineUUID'),
		'equipmentUUID': data.get('equipmentUUID'),
		'engineUUID': data.get('engineUUID'),
		'active': data.get('available'),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user')
	}
	resp = system.db.execQuery("config/addEquipmentEngine", params)
	log('resp=%s' % (resp))
	return resp

def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Deletes an equipment-engine association.
	
	Args:
		data (str|dict): JSON string, UUID, or dict with key
	
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
	resp = system.db.execQuery("config/deleteEquipmentEngine", params)
	log('resp=%s' % (resp))
	return resp