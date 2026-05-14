import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Helper function for consistent logging with function tracing.
	
	Args:
		msg (str): message to log
		
	Returns:
		None
	"""
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getBlockConfigs():
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Retrieves block configurations from the config/getBlockConfigs named query.
	
	Returns:
		list[dict]
	"""
	namedQuery = "config/getBlockConfigs"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	return resp


def getAll():
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Returns block configurations formatted for UI selectors.
	
	Returns:
		list[dict]
	"""
	log('running')
	blockConfigs = getBlockConfigs()
	resp = []
	for blockConfig in blockConfigs:
		resp.append({
			"text": blockConfig.get('name', ''),
			"view": blockConfig.get('blockConfigUUID', ''),
			"value": "",
			"key": blockConfig.get('blockConfigUUID', ''),
			"available": blockConfig.get("active", False),
		})
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Returns details about a specific block configuration given its UUID.
	
	Args:
		data (str): UUID of the block config
		
	Returns:
		dict
	"""
	log('data=%s' % (data))
	resp = {
		"name": '',
		"available": False,
		"cylinderCount": 0,
		"bankCount": 0,
		"key": '',
		"assignedNumbers": [],
		"type": "blockConfig"
	}
	
	if data:
		blockConfigs = getBlockConfigs()
		for blockConfig in blockConfigs:
			if str(blockConfig.get("blockConfigUUID")) == str(data):
				assignedNumbers = []
				try:
					if blockConfig.get("assignedNumbers"):
						assignedNumbers = system.util.jsonDecode(blockConfig.get("assignedNumbers"))
				except:
					assignedNumbers = []
				resp = {
					"name": blockConfig.get("name", ''),
					"available": blockConfig.get("active", False),
					"cylinderCount": blockConfig.get('cylinderCount', 0),
					"bankCount": blockConfig.get('bankCount', 0),
					"key": blockConfig.get("blockConfigUUID", ''),
					"assignedNumbers": assignedNumbers,
					"type": "blockConfig",
				}
				break
	
	log('resp=%s' % (resp))
	return resp


def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Adds a new block configuration with default placeholder values.
	
	Args:
		data (dict|str): JSON string or dict with user field
		
	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	params = {
		'name': 'New BlockConfig',
		'active': False,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'cylinderCount': 0,
		'bankCount': 0,
		'assignedNumbers': None,
		'blockConfigUUID': None
	}
	resp = system.db.execQuery("config/addBlockConfig", params)
	log('resp=%s' % (resp))
	return resp


def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Updates a block configuration.
	
	Args:
		data (dict|str): JSON string or dict
		
	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)

	cylinderCount = data.get('cylinderCount', 0)
	bankCount = data.get('bankCount', 0)
	
	if cylinderCount > 0 and bankCount > 0 and data.get('assignedNumbers'):
		assignedNumbers = system.util.jsonEncode(data.get('assignedNumbers'))
	else:
		assignedNumbers = system.util.jsonEncode([1] * cylinderCount)
		
	params = {
		'name': data.get('name', ''),
		'active': data.get('available', False),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'cylinderCount': cylinderCount,
		'bankCount': bankCount,
		'assignedNumbers': assignedNumbers,
		'blockConfigUUID': data.get('key', '')
	}
	resp = system.db.execQuery("config/addBlockConfig", params)
	log('resp=%s' % (resp))
	return resp


def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Archives (deletes) a block configuration by UUID or dict with key.
	
	Args:
		data (str|dict): JSON string, UUID, or dict
		
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
	resp = system.db.execQuery("config/deleteBlockConfig", params)
	log('resp=%s' % (resp))
	return resp


def getBanks(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Calculates bank groupings for a block configuration.
	
	Args:
		data (dict): block configuration details
		
	Returns:
		list[dict]
	"""
	log('data=%s' % (data))
	blockConfigKey = data.get("key")
	bankCount = data.get("bankCount", 0)
	cylinderCount = data.get("cylinderCount", 0)
	assignedNumbers = data.get("assignedNumbers", [])
	instances = []
	
	if bankCount:
		cylinderCountPerBank = int(cylinderCount / bankCount)
		for i in range(bankCount):
			bankAssignedNumbers = assignedNumbers[i * cylinderCountPerBank : i * cylinderCountPerBank + cylinderCountPerBank]
			instances.append({
				"key": blockConfigKey,
				"bankNumber": i + 1,
				"bankCount": bankCount,
				"cylinderCount": cylinderCount,
				"bankAssignedNumbers": bankAssignedNumbers
			})
	log('resp=%s' % (instances))
	return instances


def getCylinders(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Returns cylinders for a specific bank within a block configuration.
	
	Args:
		data (dict): bank details
		
	Returns:
		list[dict]
	"""
	log('data=%s' % (data))
	blockConfigKey = data.get("key", '')
	bankNumber = data.get("bankNumber", 0)
	bankCount = data.get("bankCount", 0)
	cylinderCount = data.get("cylinderCount", 0)
	bankAssignedNumbers = data.get("bankAssignedNumbers", [])
	instances = []
	
	cylindersPerBank = int(cylinderCount / bankCount) if bankCount else cylinderCount
	
	for i in range(cylindersPerBank):
		if i < len(bankAssignedNumbers):
			instances.append({"assignedNumber": bankAssignedNumbers[i]})
		else:
			instances.append({"assignedNumber": 1})
	log('resp=%s' % (instances))
	return instances