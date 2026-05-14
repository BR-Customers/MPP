import inspect

def createRecipe(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Generates a CNC recipe file content based on the selected engine, operations, and parameters.

	Args:
		data (dict): Input structure from the UI containing:
			- selectedData (dict with Cylinder, Milling, Operation, Engine)
			- extensionTypeUUID (str)
			- equipmentUUID (dict with filename)
			- rerunMode (bool)
			- selectedCylinders (list of values)
			- selectedBore
			- selectedMill

	Returns:
		str: Formatted CNC program as a string containing parameters and routine references.
	"""
#	data = {
#		'selectedData':{
#			"Cylinder": 1,
#			"Milling": "6E56773A-89B5-4736-9367-3AA447F37AF8",
#			"Operation": "B64866E6-2E83-4BA2-A4A4-EA082BFFC3BF",
#			"Engine": "BEB5D728-86BC-4A73-BA97-AE4DC1E3700F"},
#		'extensionTypeUUID' : '2B73EF83-F77A-4F24-A66D-7E0649EEC320',
#		'equipment': {},
#		'rerunMode': BOOL,
#		'selectedCylinders':[]
#		}
	
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'data={}'.format(data))
	engineUUID = data['selectedData'].value['Engine'].value
	operationUUID = data['selectedData'].value['Operation'].value #bore
	millOperationUUID = data['selectedData'].value['Milling'].value
	cylinder = data['selectedData'].value['Cylinder'].value #1=all, 2=custom
	extensionTypeUUID = data['extensionTypeUUID'].value
	equipment = data['equipmentUUID'].value
	filename = equipment['filename'].value
	rerunMode = data['rerunMode'].value
	selectedCylinders = data['selectedCylinders'].value
	selectedBore = data['selectedBore'].value
	selectedMill = data['selectedMill'].value
	if selectedCylinders:
#		selectedCylinders = selectedCylinders[0].value
#		BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'selectedCylinders={}'.format(selectedCylinders))
		
		
#		selectedCylindersFlat = [item for sublist in selectedCylinders for item in sublist]
		selectedCylindersFlat = []
		for sublist in selectedCylinders:
			sublist = sublist.getValue()
#			BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'sublist=%s' % (sublist))
			for item in sublist:
				item = item.getValue()
#				BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'item=%s' % (item))
				selectedCylindersFlat.append(item)
#		BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'selectedCylindersFlat={}'.format(selectedCylindersFlat))
		
		
		engine = BlueRidge.HMI.CNCLoader.Engine.getOne(engineUUID)
		blockConfig = engine['blockConfig']
		assignedNumbers = BlueRidge.HMI.CNCLoader.BlockConfig.getOne(blockConfig)['assignedNumbers']
		
#		selectedAssignedNumbers=[num for sel, num in zip(selectedCylindersFlat, assignedNumbers) if bool(sel)]
		reordered = [None] * len(assignedNumbers)
		for i in range(len(assignedNumbers)):
			position = assignedNumbers[i] - 1  # Convert to zero-based index
			try:
				reordered[position] = selectedCylindersFlat[i]
			except:
				reordered[position] = False
#		BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'reordered=%s' % (reordered))
		selectedCylinders = reordered
	
	#Set default ouput values:
	probeOperationParameters = None
	boreOperationParameters = None
	millOperationParameters = None
	probeRoutineName = None
	boreRoutineName = None
	millRoutineName = None
	
	#Get all operations
	operationEngines = BlueRidge.HMI.CNCLoader.OperationEngine.getOperationEngines()
	
	######################## PROBE ########################
	
	#Get Probe Filter
	operationTypes= BlueRidge.HMI.CNCLoader.OperationType.getOperationTypes()
	probeTypeFilter = next((item for item in operationTypes if 'prob' in item['name'].lower()),None)
	if not probeTypeFilter:
		BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'error={}'.format('probeTypeFilter'))
		
	#Get Probe Operations based on filter
	probeOperationTypeUUID = probeTypeFilter['operationTypeUUID']
	probeOperations = BlueRidge.HMI.CNCLoader.Operation.getAll(probeOperationTypeUUID)
	
	#Get list of all probe operations Uuids to compare against
	probeOperationUUIDs = [p.get('key') for p in probeOperations]
	
	#Get all operationEngines that are probes
	probeOperationEngines = [oe for oe in operationEngines 
		if oe['operationUUID'] in probeOperationUUIDs]

	#Get only the probe operationEngine that match the selected engine (should be just one)
#	probeOperationEngineUUID = next((oe['operationUUID'] for oe in probeOperationEngines 
#		if oe['engineUUID'] in engineUUID),None)

	#Get all the probe operationEngines that match the selected engine
	probeOperationEngines = [oe for oe in probeOperationEngines if oe['engineUUID'] in engineUUID]
	#Get only the probe operationEngine that is an active operation (should be just one)
	probeOperationEngineUUID = next((oe['operationUUID'] for oe in probeOperationEngines 
		if BlueRidge.HMI.CNCLoader.Operation.getOne(oe['operationUUID']).get('available')),None)
	
	if probeOperationEngineUUID:
		#Get Probe ParamList
		probeOperationParameterLists = BlueRidge.HMI.CNCLoader.ParameterList.getAll(probeOperationEngineUUID)
		probeOperationParameterList = next((v for v in probeOperationParameterLists if v['extensionTypeUUID'] == extensionTypeUUID),None)
		if probeOperationParameterList and probeOperationParameterList.get('verified'):
			probeOperationParameterListUUID = probeOperationParameterList['key']
			probeRoutineName = BlueRidge.HMI.CNCLoader.ParameterList.getOne(probeOperationParameterListUUID)['name']
			probeOperationName = BlueRidge.HMI.CNCLoader.Operation.getOne(probeOperationEngineUUID)['name']
			#Get Probe Params
			probeOperationParameters = BlueRidge.HMI.CNCLoader.EngineParameter.getAll(probeOperationParameterListUUID)
		else:
			BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'error={}'.format('probeOperationParameterList'))
	else:
		BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'error={}'.format('probeOperationEngineUUID'))
		
	if probeOperationParameters and rerunMode:
	    newParameters = []
	    for probeOperationParameter in probeOperationParameters:
	        if 'RerunFlag' in probeOperationParameter.get('Name', ''):
	            probeOperationParameter['Value'] = 1
	            newParameters.append(probeOperationParameter)
	    probeOperationParameters = newParameters
	######################## BORE ########################
	
	#Get Bore ParamList
	boreOperationParameterLists = BlueRidge.HMI.CNCLoader.ParameterList.getAll(operationUUID)
	boreOperationParameterList = next((v for v in boreOperationParameterLists if v['extensionTypeUUID'] == extensionTypeUUID),None)
	if boreOperationParameterList and boreOperationParameterList.get('verified'):
		boreOperationParameterListUUID = boreOperationParameterList['key']
		boreRoutineName = BlueRidge.HMI.CNCLoader.ParameterList.getOne(boreOperationParameterListUUID)['name']
		boreOperationName = BlueRidge.HMI.CNCLoader.Operation.getOne(operationUUID)['name']
		#Get Bore Params
		boreOperationParameters = BlueRidge.HMI.CNCLoader.EngineParameter.getAll(boreOperationParameterListUUID)
	else:
		BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'error={}'.format('boreOperationParameterList'))
	
	if boreOperationParameters and cylinder==2:
		for boreOperationParameter in boreOperationParameters:
			cylinderNumber = boreOperationParameter.get('Assignment')
			if cylinderNumber is not None:
				cylinderNumber = int(cylinderNumber)
#				BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'cylinderNumber={}'.format(cylinderNumber))
				if cylinderNumber>0 and cylinderNumber<=len(selectedCylinders):
					paramValue = int(selectedCylinders[cylinderNumber-1])
					boreOperationParameter['Value']=paramValue
				elif cylinderNumber < 100:
					boreOperationParameter['Value']=0
				else:
					pass
	
	#####Custom Selection#####
	if boreOperationParameters and selectedBore:
		for boreOperationParameter in boreOperationParameters:
			assignedNumber = boreOperationParameter.get('Assignment')
			if assignedNumber is not None:
				assignedNumber = int(assignedNumber)
				if assignedNumber>=100 and assignedNumber<200:
					if assignedNumber == selectedBore:
						boreOperationParameter['Value']=1
					else:
						boreOperationParameter['Value']=0
	
	if boreOperationParameters and rerunMode:
		for boreOperationParameter in boreOperationParameters:
			if 'RerunFlag' in boreOperationParameter.get('Name'):
				boreOperationParameter['Value']=1
	
	######################## MILL ########################
	
	#Get Mill ParamList
	millOperationParameterLists = BlueRidge.HMI.CNCLoader.ParameterList.getAll(millOperationUUID)
	millOperationParameterList = next((v for v in millOperationParameterLists if v['extensionTypeUUID'] == extensionTypeUUID),None)
	if millOperationParameterList and millOperationParameterList.get('verified'):
		millOperationParameterListUUID = millOperationParameterList['key']
		millRoutineName = BlueRidge.HMI.CNCLoader.ParameterList.getOne(millOperationParameterListUUID)['name']
		millOperationName = BlueRidge.HMI.CNCLoader.Operation.getOne(millOperationUUID)['name']
		#Get Mill Params
		millOperationParameters = BlueRidge.HMI.CNCLoader.EngineParameter.getAll(millOperationParameterListUUID)
	else:
		BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'error={}'.format('millOperationParameterList'))
	
	#####Custom Selection#####
	if millOperationParameters and selectedMill:
		for millOperationParameter in millOperationParameters:
			assignedNumber = millOperationParameter.get('Assignment')
			if assignedNumber is not None:
				assignedNumber = int(assignedNumber)
				if assignedNumber>=200 and assignedNumber<300:
					if assignedNumber == selectedMill:
						millOperationParameter['Value']=1
					else:
						millOperationParameter['Value']=0
	
	if millOperationParameters and rerunMode:
		for millOperationParameter in millOperationParameters:
			if 'RerunFlag' in millOperationParameter.get('Name'):
				millOperationParameter['Value']=1
	
	######################## FORMAT OUTPUT ########################
	
	#Convert parameters to text file output
#	filename=BlueRidge.HMI.CNCLoader.Equipment.getOne(equipmentUUID).get('filename')
	if filename:
		programName = filename.split('.')[0]
	description=BlueRidge.HMI.CNCLoader.Engine.getOne(engineUUID).get('name')
	headerText = "O{} ({})\n".format(programName,description)
	headerText += "M57\n"
	
	if probeOperationParameters:
		probeOperationParameters = sorted(probeOperationParameters, key=lambda x: x.get('Macro Variable'))
		probeText = "\n".join(
		    "{}={} ({})".format(item["Macro Variable"], item["Value"], item["Name"])
		    for item in probeOperationParameters	
		)
		probeText = '(PROBE:)\n'+probeText
	else:
		probeText = '(PROBE: None)'
	
	if boreOperationParameters:
		boreOperationParameters = sorted(boreOperationParameters, key=lambda x: x.get('Macro Variable'))
		boreText = "\n".join(
		    "{}={} ({})".format(item["Macro Variable"], item["Value"], item["Name"])
		    for item in boreOperationParameters
		)
		boreText = '\n(BORE:)\n'+boreText
	else:
		boreText = '\n(BORE: None)'
		
	if millOperationParameters:
		millOperationParameters = sorted(millOperationParameters, key=lambda x: x.get('Macro Variable'))
		millText = "\n".join(
		    "{}={} ({})".format(item["Macro Variable"], item["Value"], item["Name"])
		    for item in millOperationParameters
		)
		millText = '\n(MILL:)\n'+millText
	else:
		millText = '\n(MILL: None)'
	
	footerText = "\nM56\nM30"
	
	
	probeRoutineText = '\nG65 {} ({})'.format(probeRoutineName,probeOperationName) if probeRoutineName and not rerunMode else ''
	boreRoutineText = '\nG65 {} ({})'.format(boreRoutineName,boreOperationName) if boreRoutineName else ''
	millRoutineText = '\nG65 {} ({})'.format(millRoutineName,millOperationName) if millRoutineName else ''
	
	resp = headerText+probeText+boreText+millText+probeRoutineText+boreRoutineText+millRoutineText+footerText
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'resp={}'.format(resp))
	return resp
	
def saveRecipe(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Writes the generated recipe to a file.

	Args:
		data (dict): Contains 'filename' (str) and 'text' (str)

	Returns:
		int: Dummy return value (-1 on success)
	"""
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'data={}'.format(data))
	filename = data.get('filename')
	text = data.get('text')
	if filename:
#		fileExtention = filename.split('.')[-1]
#		filepath = system.file.getTempFile(fileExtention)
		filepath = "C:\Users\Public\Documents\{}".format(filename)
		system.file.writeFile(filepath, text)
		resp = -1
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'resp={}'.format(resp))
	return resp