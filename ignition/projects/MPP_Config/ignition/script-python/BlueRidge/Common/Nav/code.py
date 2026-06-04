def categoryForPath(path):
	"""
	Author: Hunter Kraft
	Date: 2026-05-06
	Returns the rail category id that owns the given page path.

	Used by Rail and NavPanel views as the single source of truth for
	URL -> category mapping. Rail-item active state and NavPanel
	category-container visibility both bind to this so they stay in
	sync as new screens are added.

	Args:
		path (str): The current Perspective page path, e.g. '/audit-log'.

	Returns:
		str: 'plant', 'parts', 'quality', 'operations', 'system', or
		     '' if the path doesn't belong to any category (home, etc).
	"""
	if path == '/plant':
		return 'plant'
	if path in ('/items', '/parts/operation-templates', '/parts/tools'):
		return 'parts'
	if path in ('/quality-specs', '/defect-codes'):
		return 'quality'
	if path in ('/downtime-codes', '/shifts'):
		return 'operations'
	if path in ('/users', '/audit-log', '/failure-log'):
		return 'system'
	return ''
