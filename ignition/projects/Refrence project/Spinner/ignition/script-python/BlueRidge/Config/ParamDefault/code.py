import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Helper for consistent project logging with automatic
	caller function tracing.
	
	Args:
		msg (str): log message
		
	Returns:
		None
	"""
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getParameterDefaults():
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Fetches all parameter defaults from recipe/getParameterDefaults.
	
	Returns:
		list[dict]
	"""
	namedQuery = "recipe/getParameterDefaults"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	return resp


def getAll(extensionTypeUUID):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Returns parameter defaults for a given extension type.
	
	Args:
		extensionTypeUUID (str): UUID of the extension type
		
	Returns:
		list[dict]
	"""
	log('data=%s' % (extensionTypeUUID))
	parameters = getParameterDefaults()
	resp = []
	for parameter in parameters:
		if parameter.get('extensionTypeUUID') == extensionTypeUUID:
			resp.append({
				"Name": parameter.get('name', ''),
				"Macro Variable": parameter.get('macroVariable', ''),
				"Value": parameter.get('macroValue', 0),
				"key": parameter.get('parameterDefaultUUID', ''),
				"operationTypeUUID": parameter.get('operationTypeUUID'),
				"Assignment": parameter.get('assignedCylinder', '')
			})
	
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Returns details of a single parameter default by UUID.
	
	Args:
		data (str): UUID
		
	Returns:
		dict
	"""
	
	resp = {}
	parameters = getParameterDefaults()
	for parameter in parameters:
		if str(parameter.get('parameterDefaultUUID')) == str(data):
			resp = parameter
			break
	
	return resp


def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Adds a new parameter default for a given extension type.
	
	Args:
		data (dict|str): JSON string or dict containing user
		
	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	extensionTypeUUID = data.get('extensionTypeUUID', '')
	if not extensionTypeUUID:
		extensionTypeUUID = getOne(data.get('key')).get('extensionTypeUUID')
		
	params = {
		'parameterDefaultUUID': None,
		'parameterUUID': None,
		'extensionTypeUUID': extensionTypeUUID,
		'name': 'New Parameter',
		'macroVariable': '',
		'macroValue': 0.0,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'operationTypeUUID': data.get('operationTypeUUID'),
		'assignedCylinder': None
	}
	resp = system.db.execUpdate("recipe/addParameterDefault", params)
	
	return resp


def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Updates a parameter default with provided data.
	
	Args:
		data (dict|str): JSON string or dict
		
	Returns:
		any - result of named query
	"""
	
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	parameterDefaultUUID = data.get('key')
	existing = getOne(parameterDefaultUUID)
	extensionTypeUUID = existing.get('extensionTypeUUID')
	
	params = {
		'parameterDefaultUUID': parameterDefaultUUID,
		'parameterUUID': data.get('parameterUUID'),
		'extensionTypeUUID': extensionTypeUUID,
		'name': data.get('Name', ''),
		'macroVariable': data.get('Macro Variable', ''),
		'macroValue': data.get('Value', 0.0),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'operationTypeUUID': data.get('operationTypeUUID'),
		'assignedCylinder': data.get('Assignment', '')
	}
	resp = system.db.execUpdate("recipe/addParameterDefault", params)
	
	return resp


def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Archives (deletes) a parameter default by UUID.
	
	Args:
		data (str|dict): JSON string, UUID, or dict
		
	Returns:
		any - result of named query
	"""
	
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	UUID = data
	if isinstance(data, dict):
		UUID = data.get('key')
		
	params = {'UUID': UUID}
	resp = system.db.execUpdate("recipe/deleteParameterDefault", params)
	
	return resp