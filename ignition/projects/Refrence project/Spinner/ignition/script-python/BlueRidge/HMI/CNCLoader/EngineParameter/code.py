import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Helper function for consistent project logging with function tracing.
	
	Args:
		msg (str): message to log
		
	Returns:
		None
	"""
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getEngineParameters():
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Fetches all engine parameters from the recipe/getEngineParameters named query.
	
	Returns:
		list[dict]
	"""
	namedQuery = "recipe/getEngineParameters"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	return [dict(zip(headers, row)) for row in results]


def getAll(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Returns all engine parameters for a given parameterListUUID.
	
	Args:
		data (str): parameterListUUID
	
	Returns:
		list[dict]
	"""
	log("data=%s" % (data))
	engineParameters = getEngineParameters()
	resp = []
	for param in engineParameters:
		if param.get("parameterListUUID") == data:
			resp.append({
				"Name": param.get("name"),
				"Macro Variable": param.get("macroVariable"),
				"Value": param.get("macroValue"),
				"Verified": param.get("validated"),
				"key": param.get("engineParameterUUID"),
				"parameterListUUID": param.get("parameterListUUID"),
				"Assignment": param.get("assignedCylinder"),
			})
	log("resp=%s" % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Returns a single engine parameter by UUID.
	
	Args:
		data (str): engineParameterUUID
	
	Returns:
		dict
	"""
	log("data=%s" % (data))
	engineParameters = getEngineParameters()
	resp = {}
	for param in engineParameters:
		if param.get("engineParameterUUID") == data:
			resp = param
			break
	log("resp=%s" % (resp))
	return resp


def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Adds a new engine parameter with default placeholder values.
	
	Args:
		data (dict|str): JSON string or dict containing user
	
	Returns:
		any
	"""
	log("data=%s" % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)

	params = {
		"parameterListUUID": data.get("parameterListUUID"),
		"engineParameterUUID": None,
		"name": "New Parameter",
		"macroVariable": None,
		"macroValue": None,
		"validated": False,
		"active": False,
		"lastEdited": system.date.now(),
		"lastEditedBy": data.get("user"),
		"assignedCylinder": None
	}
	resp = system.db.execQuery("recipe/addEngineParameter", params)
	log("resp=%s" % (resp))
	return resp


def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Updates an existing engine parameter.
	
	Args:
		data (dict|str): JSON string or dict
	
	Returns:
		any
	"""
	log("data=%s" % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)

	if data.get("parameterListUUID"):
		params = {
			"parameterListUUID": data.get("parameterListUUID"),
			"engineParameterUUID": data.get("key"),
			"name": data.get("Name"),
			"macroVariable": data.get("Macro Variable"),
			"macroValue": data.get("Value"),
			"validated": data.get("Verified"),
			"active": data.get("available"),
			"lastEdited": system.date.now(),
			"lastEditedBy": data.get("user"),
			"assignedCylinder": data.get("Assignment")
		}
		resp = system.db.execQuery("recipe/addEngineParameter", params)
	else:
		resp = "error"
	log("resp=%s" % (resp))
	return resp


def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Archives (soft deletes) an engine parameter by UUID.
	
	Args:
		data (str|dict): JSON string, UUID, or dict with key
	
	Returns:
		any
	"""
	log("data=%s" % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	UUID = data
	if isinstance(data, dict):
		UUID = data.get("key")
	params = {"UUID": UUID}
	resp = system.db.execQuery("recipe/deleteEngineParameter", params)
	log("resp=%s" % (resp))
	return resp