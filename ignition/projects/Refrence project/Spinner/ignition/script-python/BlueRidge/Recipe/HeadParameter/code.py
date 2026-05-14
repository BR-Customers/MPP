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


def getHeadParameters():
	"""
	Author: Jennifer Lewis 
	Date: 02/09/2026 
	Runs the named query to get head parameters.
	
	Returns:
		list[dict]
	"""
	log('running')
	namedQuery = "recipe/getHeadParameters"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	
	return resp


def getAll(data):
	"""
	Author: Jennifer Lewis 
	Date: 02/09/2026 
	Fetches all head parameters for a given parameterListUUID.
	
	Args:
		data (str): parameterListUUID
		
	Returns:
		list[dict]
	"""
	log('data=%s' % (data))
	headParameters = getHeadParameters()
	resp = []
	for parameter in headParameters:
		if parameter.get('parameterListUUID') == data:
			resp.append({
				"Name": parameter.get('name'),
				"Macro Variable": parameter.get('macroVariable'),
				"Value": parameter.get('macroValue'),
				"Verified": parameter.get('validated'),
				"key": parameter.get('headParameterUUID'),
				"parameterListUUID": parameter.get('parameterListUUID'),
				"Assignment": parameter.get('assignedCylinder'),
			})
	
	return resp


def getOne(data):
	"""
	Author: Jennifer Lewis 
	Date: 02/09/2026   
	Returns a single head parameter by UUID.
	
	Args:
		data (str): headParameterUUID
		
	Returns:
		dict
	"""
	log('data=%s' % (data))
	headParameters = getHeadParameters()
	resp = {}
	for parameter in headParameters:
		if parameter.get('headParameterUUID') == data:
			resp = parameter
			break
	
	return resp


def add(data):
	"""
	Author: Jennifer Lewis 
	Date: 02/09/2026  
	Adds a new head parameter with default values.
	
	Args:
		data (dict or str): payload
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	namedQuery = "recipe/addHeadParameter"
	params = {
		'parameterListUUID': data.get('parameterListUUID'),
		'headParameterUUID': None,
		'name': 'New Parameter',
		'macroVariable': None,
		'macroValue': None,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user'),
		'validated': False,
		'assignedCylinder': None
	}
	resp = system.db.execUpdate(namedQuery, params)
	
	return resp


def update(data):
	"""
	Author: Jennifer Lewis 
	Date: 02/09/2026 
	Updates an existing head parameter.
	
	Args:
		data (dict or str): parameter data
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	namedQuery = "recipe/addHeadParameter"
	parameterListUUID = data.get('parameterListUUID')
	
	if parameterListUUID:
		params = {
			'parameterListUUID': parameterListUUID,
			'headParameterUUID': data.get('key'),
			'name': data.get('Name'),
			'macroVariable': data.get('Macro Variable'),
			'macroValue': data.get('Value'),
			'lastEdited': system.date.now(),
			'lastEditedBy': data.get('user'),
			'validated': data.get('Verified'),
			'assignedCylinder': data.get('Assignment')
		}
		resp = system.db.execUpdate(namedQuery, params)
		
	else:
		resp = 'error'
		log('parameterListUUID missing, returning error')
	return resp


def archive(data):
	"""
	Author: Jennifer Lewis 
	Date: 02/09/2026 
	Archives (soft deletes) a head parameter by UUID.
	
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
		
	namedQuery = "recipe/deleteHeadParameter"
	params = {'UUID': UUID}
	resp = system.db.execUpdate(namedQuery, params)
	
	return resp