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

def getAll():
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Retrieves all active equipment records from the config/getEquipments named query.

	Returns:
		list[dict]: List of active equipment records
	"""
	log('running')
	namedQuery = "config/getEquipments"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	resp = [r for r in resp if r.get('active')]
	log('resp=%s' % (resp))
	return resp

def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Retrieves details of a specific equipment by UUID.

	Args:
		data (str): UUID of the equipment

	Returns:
		dict: Equipment details
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
					"name": equipment.get("name"),
					"ip": equipment.get("hostname"),
					"extension": equipment.get("extensionTypeUUID"),
					"filename": equipment.get("fileName"),
					"hmi": equipment.get("HMI"),
					"available": equipment.get("active"),
					"key": equipment.get("equipmentUUID"),
					"plantUUID": equipment.get("plantUUID"),
					"type": "Equipment"
				}
				break
	log('resp=%s' % (resp))
	return resp

def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Adds a new equipment record with provided details.

	Args:
		data (dict|str): JSON string or dict containing equipment details

	Returns:
		any: Result of the named query execution
	"""
	log('data=%s' % (data))
	namedQuery = "config/addEquipment"
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	params = {
		'extensionTypeUUID': data.get('extension'),
		'name': data.get('name'),
		'active': data.get('available'),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user'),
		'HMI': data.get('hmi'),
		'fileName': data.get('fileName'),
		'plantUUID': data.get('plantUUID'),
		'equipmentUUID': data.get('key'),
		'hostname': ''
	}
	resp = system.db.execQuery(namedQuery, params)
	log('resp=%s' % (resp))
	return resp

def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Updates an existing equipment record with new details.

	Args:
		data (dict|str): JSON string or dict containing updated equipment details

	Returns:
		any: Result of the named query execution
	"""
	log('data=%s' % (data))
	namedQuery = "config/addEquipment"
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	params = {
		'extensionTypeUUID': data.get('extension'),
		'name': data.get('name'),
		'active': data.get('available'),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user'),
		'HMI': data.get('hmi'),
		'fileName': data.get('filename'),
		'plantUUID': data.get('plantUUID'),
		'equipmentUUID': data.get('key'),
		'hostname': data.get('ip')
	}
	resp = system.db.execQuery(namedQuery, params)
	log('resp=%s' % (resp))
	return resp

def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Archives (deletes) an equipment record by UUID.

	Args:
		data (str|dict): JSON string, UUID, or dict containing the key

	Returns:
		any: Result of the named query execution
	"""
	log('data=%s' % (data))
	namedQuery = "config/deleteEquipment"
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	UUID = data
	if isinstance(data, dict):
		UUID = data.get('key')
	params = {'UUID': UUID}
	resp = system.db.execQuery(namedQuery, params)
	log('resp=%s' % (resp))
	return resp