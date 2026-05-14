import inspect

def log(msg):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Local logger routing to BlueRidge project logger.
	
	Args:
		msg (str): Log message
		
	Returns:
		None
	"""
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getOperations():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Runs the named query to fetch all operations.
	
	Returns:
		list[dict]
	"""
	log('running')
	namedQuery = "recipe/getOperations"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	log('resp=%s' % (resp))
	return resp


def getAll(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Returns all operations, optionally filtered by type or engine.
	
	Args:
		data (dict): filter criteria with typeFilter and/or engineFilter
		
	Returns:
		list[dict]
	"""
	log('data=%s' % (data))
	operations = getOperations()
	resp = []
	for op in operations:
		resp.append({
			"text": op.get('name'),
			"view": op.get('operationUUID'),
			"value": "",
			"key": op.get('operationUUID'),
			"type": op.get('operationTypeUUID'),
			"messageType": "OneShotButtonOperation",
			"equipmentType": op.get('equipmentType')
		})
		
	# apply filters if present
	if data:
		typeFilter = BlueRidge.Recipe.Util.extractQualifiedValues(data.get('typeFilter'))
		engineFilter = BlueRidge.Recipe.Util.extractQualifiedValues(data.get('engineFilter'))
		
		if typeFilter:
			resp = [r for r in resp if r.get('type') == typeFilter]
			
		if engineFilter:
			doubleFilteredResp = []
			operationEngines = BlueRidge.Recipe.OperationEngine.getOperationEngines()
			for r in resp:
				operationUUID = r.get('key')
				filteredEngines = [oe for oe in operationEngines if oe.get('operationUUID') == operationUUID]
				engineUUIDs = [oe.get('engineUUID') for oe in filteredEngines]
				if engineFilter in engineUUIDs:
					doubleFilteredResp.append(r)
			resp = doubleFilteredResp
			
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Returns a single operation by UUID.
	
	Args:
		data (str): operationUUID
		
	Returns:
		dict
	"""
	log('data=%s' % (data))
	resp = {
		"name": None,
		"available": False,
		"key": None,
		"type": None,
		"engines": []
	}
	
	if data:
		operations = getOperations()
		for op in operations:
			if str(op.get('operationUUID')) == str(data):
				resp = {
					"name": op.get("name"),
					"available": op.get("active"),
					"key": op.get("operationUUID"),
					"type": op.get("operationTypeUUID"),
					"engines": []
				}
				break
				
	log('resp=%s' % (resp))
	return resp


def add(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Adds a new operation, then attaches default parameters.
	
	Args:
		data (dict or str): operation info
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	namedQuery = "recipe/addOperation"
	params = {
		'operationUUID': None,
		'operationTypeUUID': data.get('operationTypeUUID'),
		'name': '_New Operation',
		'active': False,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user'),
		'equipmentType': data.get('equipmentType')
	}
	resp = system.db.execQuery(namedQuery, params)
	operationUUID = resp[0]["operationUUID"] if resp else None
	
	if operationUUID:
		# add default ParameterLists for each extension
		extensions = BlueRidge.Recipe.ExtensionType.getAll()
		for ext in extensions:
			extKey = ext.get('key')
			newData = {"typeKey": extKey, "opKey": operationUUID}
			resp = BlueRidge.Recipe.ParameterList.add(newData)
		
		# then attach default engine parameters
		parameterLists = BlueRidge.Recipe.ParameterList.getAll(operationUUID)
		for plist in parameterLists:
			plistUUID = plist.get('key')
			extUUID = plist.get('extensionTypeUUID')
			defaults = BlueRidge.Config.ParamDefault.getAll(extUUID)
			for dp in defaults:
				if dp.get('operationTypeUUID') == data.get('operationTypeUUID'):
					dp['parameterListUUID'] = plistUUID
					dp['Verified'] = False
					resp = BlueRidge.Recipe.EngineParameter.update(dp)
					
	log('resp=%s' % (resp))
	return resp


def update(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Updates an existing operation.
	
	Args:
		data (dict or str): operation data
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	namedQuery = "recipe/addOperation"
	params = {
		'operationUUID': data.get('key'),
		'operationTypeUUID': data.get('type'),
		'name': data.get('name'),
		'active': data.get('available'),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user'),
		'equipmentType': None
	}
	resp = system.db.execQuery(namedQuery, params)
	log('resp=%s' % (resp))
	return resp


def archive(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Archives (deletes) an operation and its related children (parameterLists, parameters, engines).
	
	Args:
		data (str or dict): operation UUID or dict with 'key'
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	UUID = data
	if isinstance(data, dict):
		UUID = data.get('key')
		
	# first delete children
	engines = BlueRidge.Recipe.OperationEngine.getAll(UUID)
	for engine in engines:
		BlueRidge.Recipe.OperationEngine.archive(engine.get('key'))
		
	parameterLists = BlueRidge.Recipe.ParameterList.getAll(UUID)
	for plist in parameterLists:
		parameters = BlueRidge.Recipe.EngineParameter.getAll(plist.get('key'))
		for param in parameters:
			BlueRidge.Recipe.EngineParameter.archive(param.get('key'))
		BlueRidge.Recipe.ParameterList.archive(plist.get('key'))
		
	# finally delete the operation
	namedQuery = "recipe/deleteOperation"
	params = {"UUID": UUID}
	resp = system.db.execUpdate(namedQuery, params)
	log('resp=%s' % (resp))
	return resp

def getOperationEquipmentForDropdown():
	"""
	Author: Jennifer Lewis
	Date: 02/05/2026
	Retrieves unique equipment types from the recipe/getEquipmentTypes named query and formats them for a dropdown component.
	
	Returns:
		list[dict]
	"""
	allOperations = system.db.execQuery('recipe/getEquipmentTypes')
	equipmentTypes = []
	for operation in allOperations:
		dropdown = {
			'label': operation['equipmentType'].capitalize(),
			'value': operation['equipmentType']
		}
		equipmentTypes.append(dropdown)
	
	return equipmentTypes

def getOperationsByHeadForDropdown(head):
	"""
	Author: Hunter Kraft
	Date: 02/10/2026
	Retrieves the operations that a provided head is assigned to.
	
	Returns:
		list[dict]
	"""
	allOperations = system.db.execQuery('recipe/getOperationsByHead', parameters = {'head': head})
	operations = []
	for operation in allOperations:
		dropdown = {
			'label': operation['name'],
			'value': operation['headOperationUUID']
		}
		operations.append(dropdown)
	
	return operations