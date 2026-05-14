def convertToArray(dataset):
	columns = system.dataset.getColumnHeaders(dataset)
	data = []
	for row in range(dataset.getRowCount()):
		row_obj = {}
		for column in range(dataset.getColumnCount()):
			row_obj[columns[column]] = dataset.getValueAt(row, column)
		data.append(row_obj)
	return data

def _norm_uuid(u):
        return (u or '').strip().lower()

def _parse_value(v):
    """Prefer numeric macro values when possible; otherwise return raw."""
    try:
        if v is None:
            return None
        # Jython may have long
        if isinstance(v, (int, float, long)):
            return float(v)
        return float(str(v).strip())
    except:
        return v

def _to_clean_string(val):
    """Format numbers nicely for output (e.g., 1.0 -> 1)."""
    try:
        f = float(val)
        if f.is_integer():
            return str(int(f))
        return str(f)
    except:
        return str(val)

def _norm_ext(ext):
    ext = (ext or "").strip()
    if ext and not ext.startswith("."):
        ext = "." + ext
    return ext

def _set_or_append_qvar(qvars, name, value):
    """Override first match; if not found append. Does NOT remove duplicates."""
    for v in qvars:
        if v.get('macroVariable') == name:
            v['macroValue'] = value
            return
    qvars.append({'macroVariable': name, 'macroValue': value})

def _get_first_qvar_value(qvars, name):
    for v in qvars:
        if v.get('macroVariable') == name:
            return v.get('macroValue')
    return None

def generateCNCFile(data):
    """
    Generates qVariables and downloads a CNC variable file in Perspective.

    Filename: VARIABLES.<extension>
      - PartNumber comes from Q31 (first occurrence)
      - Date is current date (yyyyMMdd)
      - Extension comes from extensionTypeResp['extension'] (e.g. 'cnc' or '.cnc')

    File content:
      Each line: <macroVariable>=<macroValue>
      Plus QL1 forced to 1 if process == 'rework' else 0

    Returns:
      dict with filename, content, qVariables, allVariables, allWidgets
    """

    extension  = data['extensionType']
    groups     = data['selectedButtons']     # [{operationUUID, selections:[{widgetUUID, selected}]}]
    operations = data['selectedOperation']   # [operationUUID]
    process    = data.get('process', 'new')  # 'new' or 'rework'
    depth = data['depth']
    probed = data['probed']
	
    allVariables = []
    allWidgets   = []
    qVariables   = []

    extensionTypeResp = BlueRidge.Config.ExtensionType.getOne(extension)
    # ---------------- 1) collect variables (KEEP DUPLICATES) ----------------
    for op in operations:
        rows = system.db.execQuery(
            'recipe/getHeadOperationParameters',
            {'operationType': op, 'extensionType': extension}
        )
        allVariables.extend(convertToArray(rows))

    # ---------------- 2) GLOBAL selection map: widgetUUID -> selectedBool ----------------
    # Use widget UUIDs only (avoids operationUUID domain mismatch).
    selected_by_widget_uuid = {}
    for group in groups:
        for btn in group.get('selections', []):
            selected_by_widget_uuid[_norm_uuid(btn.get('widgetUUID'))] = btn.get('selected')

    # ---------------- 3) collect widget config rows + stamp selected flag ----------------
    for group in groups:
        op_uuid = group.get('operationUUID')

        op_cfg = BlueRidge.Config.HeadConfig.getHeadOperation(op_uuid)
        widgets = (op_cfg[0].get('widgets', []) if op_cfg else [])

        for w in widgets:
            # Your existing approach:
            head_widget_uuid = w['viewParams']['buttonIndex']

            widgetRows = system.db.execQuery(
                'config/getHeadWidget',
                {'extensionTypeUUID': extension, 'headWidgetUUID': head_widget_uuid}
            )
            widgetArr = convertToArray(widgetRows)
            if not widgetArr:
                continue

            widgetData = widgetArr[0]

            wid_key = _norm_uuid(widgetData.get('headWidgetUUID'))
            widgetData['selected'] = selected_by_widget_uuid.get(wid_key, 0)

            allWidgets.append(widgetData)

    # ---------------- 4) index widgets by parameter UUID ----------------
    widgets_by_param_uuid = {}
    for w in allWidgets:
        param_key = _norm_uuid(w.get('selectedVariable'))  # points to headParameterUUID
        if param_key:
            widgets_by_param_uuid.setdefault(param_key, []).append(w)

    # ---------------- 5) build qVariables (KEEP DUPLICATES) ----------------
    for var in allVariables:
        param_key  = _norm_uuid(var.get('headParameterUUID'))
        macro_name = var.get('macroVariable')

        # default fallback: macroValue from variable row
        final_value = _parse_value(var.get('macroValue'))

        # if widget controls this parameter, use widget selected/notSelected values
        widget_list = widgets_by_param_uuid.get(param_key, [])
        if widget_list:
            # If multiple widgets map to same parameter, prefer one present in selection map
            chosen = None
            for w in widget_list:
                if _norm_uuid(w.get('headWidgetUUID')) in selected_by_widget_uuid:
                    chosen = w
                    break
            if chosen is None:
                chosen = widget_list[0]
            system.perspective.print(chosen)
            if chosen.get('selected') == 1:
        		val = chosen.get('selectedValue')
            elif chosen.get('selected') == 2:
        		val = 2
            else:
        		val = chosen.get('notSelectedValue')
            final_value = _parse_value(
            	val
            )

        qVariables.append({'macroVariable': macro_name, 'macroValue': final_value})

    # ---------------- 6) force QL1 based on process ----------------
    ql1_value = 1 if process == 'rework' else 0
    _set_or_append_qvar(qVariables, 'QL1', ql1_value)
    _set_or_append_qvar(qVariables, depth['variable'], depth['value'])
    _set_or_append_qvar(qVariables, probed['variable'], probed['value'])

    # ---------------- 7) build file content ----------------
    lines = []
    lines.append(u"BEGIN PGM VARS INCH")
    for v in qVariables:
        lines.append(u"{0}={1}".format(v.get('macroVariable'), _to_clean_string(v.get('macroValue'))))
    lines.append(u"END PGM VARS INCH")
    # CRLF tends to be safest for CNC/Windows tooling
    content = u"\r\n".join(lines) + u"\r\n"

    # ---------------- 8) build file name: <Q31>_<yyyyMMdd>.<extension> ----------------
    part_number = _get_first_qvar_value(qVariables, 'Q31')
    part_str = _to_clean_string(part_number) if part_number is not None else "UNKNOWNPART"

    date_str = system.date.format(system.date.now(), "yyyyMMdd")
    ext = _norm_ext(extensionTypeResp.get('extension'))

    filename = 'VARIABLES'
	
    return {
        "filename": filename,
        "content": content
    }