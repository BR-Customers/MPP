import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Helper logging with function context for consistent tracing.
	
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
	Returns all active assets from config/getAssets named query.
	
	Returns:
		list[dict]
	"""
	log('running')
	namedQuery = "config/getAssets"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	resp = [r for r in resp if r.get('active', False)]
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Returns a single asset details.
	
	Args:
		data (str): assetUUID
		
	Returns:
		dict
	"""
	log('data=%s' % (data))
	resp = {
		"name": '',
		"ip": '',
		"available": False,
		"key": None,
		"equipmentUUID": None,
		"type": "Asset"
	}
	
	if data:
		assets = getAll()
		for asset in assets:
			if str(asset.get("assetUUID")) == str(data):
				resp = {
					"name": asset.get('name', ''),
					"ip": asset.get('hostname', ''),
					"available": asset.get('active', False),
					"key": asset.get('assetUUID'),
					"equipmentUUID": asset.get('equipmentUUID'),
					"type": "Asset"
				}
				break
	log('resp=%s' % (resp))
	return resp


def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Adds a new asset.
	
	Args:
		data (dict): Asset data
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)

	params = {
		'name': data.get('name', ''),
		'hostname': data.get('ip', ''),
		'lastActivated': system.date.now(),
		'equipmentUUID': data.get('equipmentUUID'),
		'assetUUID': None,
		'active': False,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', '')
	}
	resp = system.db.execQuery("config/addAsset", params)
	log('resp=%s' % (resp))
	return resp


def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Updates an existing asset.
	
	Args:
		data (dict): Asset data
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)

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
	Date: 07/07/2025
	Archives (deletes) an asset by UUID.
	
	Args:
		data (str|dict): UUID or dict
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, dict):
		UUID = data.get('key')
	else:
		UUID = data
		
	params = {'UUID': UUID}
	resp = system.db.execQuery("config/deleteAsset", params)
	log('resp=%s' % (resp))
	return resp