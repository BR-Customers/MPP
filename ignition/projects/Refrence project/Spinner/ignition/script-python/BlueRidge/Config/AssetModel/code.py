import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Helper function for consistent project logging with caller tracing.
	
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
	Builds a hierarchical tree of plants, equipment, and assets
	for use in a tree selector.
	
	Returns:
		list[dict]
	"""
	log('running')
	
	plants = BlueRidge.Config.Plant.getAll()
	equipments = BlueRidge.Config.Equipment.getAll()
	assets = BlueRidge.Config.Asset.getAll()

	# Index equipment by plantUUID
	equipment_by_plant = {}
	for equipment in equipments:
		plant_key = equipment.get("plantUUID")
		equipment["children"] = []
		equipment_by_plant.setdefault(plant_key, []).append(equipment)

	# Index assets by equipmentUUID
	asset_by_equipment = {}
	for asset in assets:
		equipment_key = asset.get("equipmentUUID")
		asset_by_equipment.setdefault(equipment_key, []).append(asset)

	# Attach assets to equipment
	for equipment in equipments:
		equipment_key = equipment.get("equipmentUUID")
		equipment["children"] = asset_by_equipment.get(equipment_key, [])

	# Attach equipment to plants
	for plant in plants:
		plant_key = plant.get("plantUUID")
		plant["children"] = equipment_by_plant.get(plant_key, [])

	# Build the tree structure
	resp = []

	for plant in plants:
		plant_node = {
			"label": plant.get("name", "Unnamed Plant"),
			"expanded": True,
			"icon": {
				"path": "material/apartment",
				"color": "",
				"style": {}
			},
			"data": {
				"key": plant.get("plantUUID", None)
			},
			"items": []
		}

		for equipment in plant.get("children", []):
			equipment_node = {
				"label": equipment.get("name", "Unnamed Equipment"),
				"expanded": True,
				"icon": {
					"path": "material/settings_applications",
					"color": "",
					"style": {}
				},
				"data": {
					"key": equipment.get("equipmentUUID", None)
				},
				"items": []
			}

			for asset in equipment.get("children", []):
				asset_node = {
					"label": asset.get("name", "Unnamed Asset"),
					"expanded": False,
					"icon": {
						"path": "material/tablet_mac",
						"color": "",
						"style": {}
					},
					"data": {
						"key": asset.get("assetUUID", None)
					},
					"items": []
				}
				equipment_node["items"].append(asset_node)

			plant_node["items"].append(equipment_node)

		resp.append(plant_node)

	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Placeholder for retrieving a single hierarchy node.
	
	Args:
		data (any): payload
	
	Returns:
		str
	"""
	log('data=%s' % (data))
	return 'success'


def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Adds a new plant, equipment, or asset based on type provided.
	
	Args:
		data (str): JSON string
		
	Returns:
		any - result of child add function
	"""
	log('data=%s' % (data))
	data = system.util.jsonDecode(data)
	typeSelected = data.get('type')
	typeToAdd = data.get('scripttype')
	resp = None

	if typeToAdd == 'Plant':
		data['name'] = 'New Plant'
		data['available'] = False
		data['key'] = None
		resp = BlueRidge.Config.Plant.add(data)

	elif typeToAdd == 'Equipment':
		data['name'] = 'New Equipment'
		data['available'] = False
		data['extension'] = None
		data['hmi'] = None
		data['fileName'] = None
		
		if typeSelected == 'Plant':
			data['plantUUID'] = data.get('key')
		elif typeSelected == 'Equipment':
			pass  # no change
		elif typeSelected == 'Asset':
			equipment = BlueRidge.Config.Equipment.getOne(data.get('equipmentUUID'))
			data['plantUUID'] = equipment.get('plantUUID')
		else:
			return 'error'
			
		data['key'] = None
		resp = BlueRidge.Config.Equipment.add(data)

	elif typeToAdd == 'Asset':
		data['name'] = 'New Asset'
		data['available'] = False
		data['ip'] = None
		
		if typeSelected == 'Plant':
			return 'error'
		elif typeSelected == 'Equipment':
			data['equipmentUUID'] = data.get('key')
		elif typeSelected == 'Asset':
			pass
		else:
			return 'error'
			
		data['key'] = None
		resp = BlueRidge.Config.Asset.add(data)

	else:
		log('invalid typeToAdd: %s' % (typeToAdd))
		resp = 'error'
		
	return resp


def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Archives an existing plant, equipment, or asset based on its type.
	
	Args:
		data (str): JSON string
		
	Returns:
		any - result of child archive function
	"""
	log('data=%s' % (data))
	data = system.util.jsonDecode(data)
	typeSelected = data.get('type')
	resp = None

	if typeSelected == 'Plant':
		resp = BlueRidge.Config.Plant.archive(data)
	elif typeSelected == 'Equipment':
		resp = BlueRidge.Config.Equipment.archive(data)
	elif typeSelected == 'Asset':
		resp = BlueRidge.Config.Asset.archive(data)
	else:
		log('invalid typeSelected: %s' % (typeSelected))
		
	return resp