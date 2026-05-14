def handleTimerEvent():
	tags = system.opc.browse('SpinnerCNC', folderPath = '*FileSystem/TNC/nc_prog/VARS.h')
	try:
		system.tag.writeBlocking(['[default]VARSFileId'], [str(tags[0].getOpcItemPath())])
	except:
		system.tag.writeBlocking(['[default]VARSFileId'], ['MissingFile'])
		ncId = system.opc.browse('SpinnerCNC', folderPath = '*FileSystem/TNC/nc_prog')[0].getOpcItemPath()
		system.tag.writeBlocking(['[default]NC_ProgId'], [str(ncId)])