import inspect

def getEquipmentEngines():
	namedQuery = "config/getEquipmentEngines"
	results = system.db.execQuery(namedQuery)
	headers=list(results.getColumnNames())
#	headers = ["engineUUID", "plantUUID", "name", "active", "lastEdited", "lastEditedBy"]
	resp = [dict(zip(headers, row)) for row in results]
	return resp

def getAll(data):
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'data={}'.format(data))
	equipmentEngines = getEquipmentEngines()
	resp = []
	for equipmentEngine in equipmentEngines:
		if equipmentEngine.get('equipmentUUID')==data:
			engine = BlueRidge.Config.Engine.getOne(equipmentEngine.get('engineUUID'))
			resp.append({
				"text": engine['name'],
				"view": equipmentEngine['equipmentEngineUUID'],
				"value": "",
				"key": equipmentEngine['equipmentEngineUUID'],
				"equipmentUUID":equipmentEngine['equipmentUUID'],
				"engineUUID":equipmentEngine['engineUUID'],
			})
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'resp={}'.format(resp))
	return resp

def getOne(data):
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'data={}'.format(data))
	if data or data != 0:
		equipmentEngines = getEquipmentEngines()
		resp = {}
		for equipmentEngine in equipmentEngines:
			if equipmentEngine['equipmentEngineUUID']==data:
				resp = equipmentEngine
#	else:
#		resp = {
#			"name": '',
#			"available": False,
#			"key": '',
#			"blockConfig": '',
#		}
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'resp={}'.format(resp))
	return resp
	
def add(data):
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'data={}'.format(data))
#	EXEC config.addEquipmentEngine 
#	@equipmentUUID=:equipmentUUID, 
#	@engineUUID=:engineUUID, 
#	@active=:active, 
#	@lastEdited=:lastEdited, 
#	@lastEditedBy=:lastEditedBy,
#	@equipmentEngineUUID=:equipmentEngineUUID
	namedQuery = "config/addEquipmentEngine"
	if type(data) == str:
		data = system.util.jsonDecode(data)
	equipmentEngineUUID=None
	equipmentUUID=data.get('equipmentUUID')
	engineUUID=data.get('engineUUID')
	active=False
	lastEdited=system.date.now()
	lastEditedBy=data.get('user')
	params = {
		'equipmentEngineUUID':equipmentEngineUUID,
		'equipmentUUID':equipmentUUID, 
		'engineUUID':engineUUID, 
		'active':active, 
		'lastEdited':lastEdited,
		'lastEditedBy':lastEditedBy}
	resp = system.db.execQuery(namedQuery,params)
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'resp={}'.format(resp))
	return resp
def archive(data):
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'data={}'.format(data))
	namedQuery = "config/deleteEquipmentEngine"
	data = system.util.jsonDecode(data)
	UUID = data
	if type(data) == dict:
		UUID=data.get('key')
	params = {'UUID':UUID}
	resp = system.db.execQuery(namedQuery,params)
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'resp={}'.format(resp))
	return resp
def update(data):
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'data={}'.format(data))
	namedQuery = "config/addEquipmentEngine"
	if type(data) == str:
		data = system.util.jsonDecode(data)
	equipmentEngineUUID=data.get('equipmentEngineUUID')
	equipmentUUID=data.get('equipmentUUID')
	engineUUID=data.get('engineUUID')
	active=data.get('available')
	lastEdited=system.date.now()
	lastEditedBy=data.get('user')
	params = {
		'equipmentEngineUUID':equipmentEngineUUID,
		'equipmentUUID':equipmentUUID, 
		'engineUUID':engineUUID, 
		'active':active, 
		'lastEdited':lastEdited,
		'lastEditedBy':lastEditedBy}
	resp = system.db.execQuery(namedQuery,params)
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'resp={}'.format(resp))
	return resp