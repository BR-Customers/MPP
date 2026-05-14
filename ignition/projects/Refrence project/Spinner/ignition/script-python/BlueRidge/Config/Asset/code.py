import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Logging helper for consistent function tracing.
	
	Args:
		msg (str): The message to log
		
	Returns:
		None
	"""
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getAll():
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Retrieves all asset records from the named query config/getAssets and returns them
	as a list of dictionaries with column headers as keys.
	
	Returns:
		list[dict] - list of asset records
	"""
	log('running')
	namedQuery = "config/getAssets"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Gets a single asset by assetUUID, returning a simplified dictionary of
	asset details. If no match is found, returns an empty template.
	
	Args:
		data (str): assetUUID to search for
		
	Returns:
		dict - asset record with name, ip, available, key, equipmentUUID, and type
	"""
	log('data=%s' % (data))
	resp = {
		"name": '',
		"ip": '',
		"available": False,
		"key": '',
		"equipmentUUID": '',
		"type": "Asset"
	}
	
	if data:
		assets = getAll()
		for asset in assets:
			if str(asset.get("assetUUID")) == str(data):
				resp = {
					"name": asset.get('name'),
					"ip": asset.get('hostname'),
					"available": asset.get('active'),
					"key": asset.get('assetUUID'),
					"equipmentUUID": asset.get('equipmentUUID'),
					"type": "Asset"
				}
				break  # no need to keep looping after a match
	
	log('resp=%s' % (resp))
	return resp


def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Adds or updates an asset record using a named query.
	
	Args:
		data (dict): asset details containing at least name, ip, equipmentUUID, user, etc.
		
	Returns:
		any - result of the named query execution
	"""
	log('data=%s' % (data))
	params = {
		'name': data.get('name', ''),
		'hostname': data.get('ip', ''),
		'lastActivated': system.date.now(),
		'equipmentUUID': data.get('equipmentUUID'),
		'assetUUID': data.get('key'),
		'active': data.get('available', False),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', '')
	}
	resp = system.db.execQuery("config/addAsset", params)
	log('resp=%s' % (resp))
	return resp


def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Archives (deletes) an asset by UUID or by asset dict.
	
	Args:
		data (str|dict): asset UUID or dict with 'key' property
		
	Returns:
		any - result of the named query execution
	"""
	log('data=%s' % (data))
	UUID = data
	if isinstance(data, dict):
		UUID = data.get('key')
	params = {'UUID': UUID}
	resp = system.db.execQuery("config/deleteAsset", params)
	log('resp=%s' % (resp))
	return resp


def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Updates an asset by re-calling the add() function.
	
	Args:
		data (dict): asset details
		
	Returns:
		any - result of the add() function
	"""
	log('data=%s' % (data))
	resp = add(data)
	log('resp=%s' % (resp))
	return resp