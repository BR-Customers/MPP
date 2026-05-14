import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Helper for consistent logging with caller function name.
	
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
	Retrieves all plant records from the named query config/getPlants and returns them
	as a list of dictionaries.
	
	Returns:
		list[dict] - list of plants
	"""
	log('running')
	namedQuery = "config/getPlants"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	log('resp=%s' % (resp))
	return resp

def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Gets a single plant by plantUUID, returning a simplified dictionary of details.
	If no match is found, returns a blank template.
	
	Args:
		data (str): plantUUID
	
	Returns:
		dict - plant details
	"""
	log('data=%s' % (data))
	resp = {
		"name": '',
		"location": '',
		"available": False,
		"key": '',
		"type": "Plant"
	}
	if data:
		plants = getAll()
		for plant in plants:
			if str(plant.get("plantUUID")) == str(data):
				resp = {
					"name": plant.get("name"),
					"location": plant.get("location"),
					"available": plant.get("active"),
					"key": plant.get("plantUUID"),
					"type": "Plant"
				}
				break
	log('resp=%s' % (resp))
	return resp

def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Adds or updates a plant using the named query config/addPlant.
	
	Args:
		data (dict): plant details
	
	Returns:
		any - result of the named query
	"""
	log('data=%s' % (data))
	params = {
		'plantUUID': data.get('key', ''),
		'name': data.get('name', ''),
		'active': data.get('available', False),
		'location': data.get('location', ''),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', '')
	}
	resp = system.db.execQuery("config/addPlant", params)
	log('resp=%s' % (resp))
	return resp

def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Archives (deletes) a plant record by UUID or plant dictionary.
	
	Args:
		data (str|dict): plantUUID or plant dict with 'key'
	
	Returns:
		any - result of the named query
	"""
	log('data=%s' % (data))
	UUID = data
	if isinstance(data, dict):
		UUID = data.get('key')
	params = {'UUID': UUID}
	resp = system.db.execQuery("config/deletePlant", params)
	log('resp=%s' % (resp))
	return resp

def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Updates a plant record by reusing the add() logic.
	
	Args:
		data (dict): plant details
	
	Returns:
		any - result of the add() function
	"""
	log('data=%s' % (data))
	resp = add(data)
	log('resp=%s' % (resp))
	return resp

def getHMI():
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Returns static HMI views list for use in Perspective or Vision.
	
	Returns:
		list[dict] - HMI view options
	"""
	log('running')
	resp = [
		{"text": "CNC Loader", "view": "/hmi/cncloader", "key": '1'},
		{"text": "ROD Machine", "view": "/hmi/cncloader/recipeselection", "key": '2'}
	]
	log('resp=%s' % (resp))
	return resp