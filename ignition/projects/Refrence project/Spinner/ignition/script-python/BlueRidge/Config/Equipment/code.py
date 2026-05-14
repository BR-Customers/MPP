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


def getAll():
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Retrieves all equipment records from the config/getEquipments named query
	and returns them as a list of dictionaries.
	
	Returns:
		list[dict] - equipment records
	"""
	log('running')
	namedQuery = "config/getEquipments"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Returns details about a specific equipment given its UUID.
	
	Args:
		data (str): UUID of the equipment
		
	Returns:
		dict - equipment details
	"""
	log('data=%s' % (data))
	resp = {
		"name": '',
		"ip": '',
		"extension": '',
		"filename": '',
		"hmi": '',
		"available": False,
		"key": '',
		"plantUUID": '',
		"type": "Equipment"
	}
	
	if data:
		equipments = getAll()
		for equipment in equipments:
			if str(equipment.get("equipmentUUID")) == str(data):
				resp = {
					"name": equipment.get("name", ''),
					"ip": equipment.get("hostname", ''),
					"extension": equipment.get("extensionTypeUUID", ''),
					"filename": equipment.get("fileName", ''),
					"hmi": equipment.get("HMI", ''),
					"available": equipment.get("active", False),
					"key": equipment.get("equipmentUUID", ''),
					"plantUUID": equipment.get("plantUUID", ''),
					"type": "Equipment"
				}
				break
	
	log('resp=%s' % (resp))
	return resp


def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Adds a new equipment entry using the config/addEquipment named query.
	
	Args:
		data (dict): equipment details
		
	Returns:
		any - result of the named query execution
	"""
	log('data=%s' % (data))
	params = {
		'extensionTypeUUID': data.get('extension', ''),
		'name': data.get('name', ''),
		'active': data.get('available', False),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'HMI': data.get('hmi', ''),
		'fileName': data.get('filename', ''),
		'plantUUID': data.get('plantUUID', ''),
		'equipmentUUID': data.get('key', ''),
		'hostname': data.get('ip', '')
	}
	resp = system.db.execQuery("config/addEquipment", params)
	log('resp=%s' % (resp))
	return resp


def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Archives (soft deletes) an equipment by UUID or by dict with a key property.
	
	Args:
		data (str|dict): equipment UUID or equipment dict
		
	Returns:
		any - result of the named query execution
	"""
	log('data=%s' % (data))
	UUID = data
	if isinstance(data, dict):
		UUID = data.get('key')
	params = {'UUID': UUID}
	resp = system.db.execQuery("config/deleteEquipment", params)
	log('resp=%s' % (resp))
	return resp


def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Updates an existing equipment by reusing the add() function with
	the same parameters.
	
	Args:
		data (dict): equipment details
		
	Returns:
		any - result of the add() function
	"""
	log('data=%s' % (data))
	resp = add(data)
	log('resp=%s' % (resp))
	return resp