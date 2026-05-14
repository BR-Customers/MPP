import inspect

def log(msg):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Local logging helper that routes to project logger.
	
	Args:
		msg (str): Message to log
		
	Returns:
		None
	"""
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getEngineParameters():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Runs the named query to get engine parameters.
	
	Returns:
		list[dict]
	"""
	log('running')
	namedQuery = "recipe/getEngineParameters"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	log('resp=%s' % (resp))
	return resp


def getAll(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Fetches all engine parameters for a given parameterListUUID.
	
	Args:
		data (str): parameterListUUID
		
	Returns:
		list[dict]
	"""
	log('data=%s' % (data))
	engineParameters = getEngineParameters()
	resp = []
	for parameter in engineParameters:
		if parameter.get('parameterListUUID') == data:
			resp.append({
				"Name": parameter.get('name'),
				"Macro Variable": parameter.get('macroVariable'),
				"Value": parameter.get('macroValue'),
				"Verified": parameter.get('validated'),
				"key": parameter.get('engineParameterUUID'),
				"parameterListUUID": parameter.get('parameterListUUID'),
				"Assignment": parameter.get('assignedCylinder'),
			})
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Returns a single engine parameter by UUID.
	
	Args:
		data (str): engineParameterUUID
		
	Returns:
		dict
	"""
	log('data=%s' % (data))
	engineParameters = getEngineParameters()
	resp = {}
	for parameter in engineParameters:
		if parameter.get('engineParameterUUID') == data:
			resp = parameter
			break
	log('resp=%s' % (resp))
	return resp


def add(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Adds a new engine parameter with default values.
	
	Args:
		data (dict or str): payload
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	namedQuery = "recipe/addEngineParameter"
	params = {
		'parameterListUUID': data.get('parameterListUUID'),
		'engineParameterUUID': None,
		'name': 'New Parameter',
		'macroVariable': None,
		'macroValue': None,
		'active': False,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user'),
		'validated': False,
		'assignedCylinder': None
	}
	resp = system.db.execQuery(namedQuery, params)
	log('resp=%s' % (resp))
	return resp


def update(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Updates an existing engine parameter.
	
	Args:
		data (dict or str): parameter data
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	namedQuery = "recipe/addEngineParameter"
	parameterListUUID = data.get('parameterListUUID')
	
	if parameterListUUID:
		params = {
			'parameterListUUID': parameterListUUID,
			'engineParameterUUID': data.get('key'),
			'name': data.get('Name'),
			'macroVariable': data.get('Macro Variable'),
			'macroValue': data.get('Value'),
			'active': data.get('available'),
			'lastEdited': system.date.now(),
			'lastEditedBy': data.get('user'),
			'validated': data.get('Verified'),
			'assignedCylinder': data.get('Assignment')
		}
		resp = system.db.execUpdate(namedQuery, params)
		log('resp=%s' % (resp))
	else:
		resp = 'error'
		log('parameterListUUID missing, returning error')
	return resp


def archive(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Archives (soft deletes) an engine parameter by UUID.
	
	Args:
		data (str or dict): parameter UUID or dict containing 'key'
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	UUID = data
	if isinstance(data, dict):
		UUID = data.get('key')
		
	namedQuery = "recipe/deleteEngineParameter"
	params = {'UUID': UUID}
	resp = system.db.execUpdate(namedQuery, params)
	log('resp=%s' % (resp))
	return resp