extends Node
class_name HelperFunctions


# Returns all resource within the directory path
static func get_all_resources_in(path: String) -> Array[Resource]:
	if not path.ends_with('/'): printerr("path doesn't end with '/'")
	var resources: Array[Resource] = []
	var files := DirAccess.get_files_at(path)
	for file in files:
		if file.ends_with('.tres'):
			var loaded_file := load(path+file)
			if loaded_file is Resource:
				resources.append(loaded_file)
	return resources

static func get_all_children(node: Node) -> Array[Node]:
	var nodes : Array[Node] = []
	for N in node.get_children():
		if N.get_child_count() > 0:
			nodes.append(N)
			nodes.append_array(get_all_children(N))
		else:
			nodes.append(N)
	return nodes


