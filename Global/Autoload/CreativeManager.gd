extends Node

# Server-authoritative creative-mode map editing. A dev in creative mode grabs any solid body in
# the map and moves/rotates it; every edit routes through here so the host owns the canonical
# layout and all peers stay in sync. Walls live in the deterministic Map
# subtree, so a node is addressed by its path relative to that Map node — identical on every peer.
#
# Layouts persist as per-map overrides in user:// and re-apply on load. A finished layout can be
# packed into a standalone player map (user://maps) for local testing, or promoted into the repo
# (res://Screens/Maps) so it can be committed as a real built-in map.

const OVERRIDE_DIR := "user://layouts"
const PLAYER_MAP_DIR := "user://maps"
const BUILT_IN_MAP_DIR := "res://Screens/Maps"

# map_path -> { rel_path:String -> Transform3D }. Canonical, in-memory edits; mirrored to disk by
# save_layout() and re-applied by notify_map_loaded(). Loaded for every known map on boot.
var _overrides := {}

func _ready() -> void:
	_load_all_overrides()

# Creative is dev-only, gated solely by the root's dev_mode. With dev_mode on it's available any
# time — including mid-match — so devs can flip it whenever. Re-checked on the server before any
# edit is applied, so the rule holds for remote peers too.
func creative_allowed() -> bool:
	var root := _game_root()
	return root != null and root.dev_mode

# --- Node addressing -------------------------------------------------------

func map_node() -> Node3D:
	var root := _game_root()
	if root == null:
		return null
	return root.map_container.get_node_or_null("Map")

func current_map_path() -> String:
	var root := _game_root()
	return root.current_map_path if root else ""

func _node(rel_path: String) -> Node3D:
	var map := map_node()
	if map == null:
		return null
	return map.get_node_or_null(rel_path) as Node3D

# A body the server will let creative move: any node resolvable under the Map subtree, except a
# grabbable ball (those keep their own networked authority). rel_path is relative to Map, so the
# lookup itself already confines edits to map geometry — a peer can't address a player this way.
func _editable_node(rel_path: String) -> Node3D:
	var node := _node(rel_path)
	if node == null or node is Grabbable:
		return null
	return node

# --- Edit flow (peer -> server -> all peers) -------------------------------

# Begin moving a wall: drop its collision so the dragging dev (and others) don't get shoved.
func begin_edit(rel_path: String) -> void:
	if multiplayer.is_server():
		_server_begin_edit(rel_path)
	else:
		_req_begin_edit.rpc_id(1, rel_path)

# Live drag updates — unreliable, the final commit is the authoritative one.
func stream_transform(rel_path: String, xform: Transform3D) -> void:
	if multiplayer.is_server():
		_apply_transform.rpc(rel_path, xform)
	else:
		_req_transform.rpc_id(1, rel_path, xform)

# Drop the wall: apply the final transform, restore collision, and record it as an override.
func commit_transform(rel_path: String, xform: Transform3D) -> void:
	if multiplayer.is_server():
		_apply_commit.rpc(rel_path, xform)
	else:
		_req_commit.rpc_id(1, rel_path, xform)

@rpc("any_peer", "reliable")
func _req_begin_edit(rel_path: String) -> void:
	if _sender_ok():
		_server_begin_edit(rel_path)

@rpc("any_peer", "unreliable")
func _req_transform(rel_path: String, xform: Transform3D) -> void:
	if _sender_ok() and _editable_node(rel_path) != null:
		_apply_transform.rpc(rel_path, xform)

@rpc("any_peer", "reliable")
func _req_commit(rel_path: String, xform: Transform3D) -> void:
	if _sender_ok() and _editable_node(rel_path) != null:
		_apply_commit.rpc(rel_path, xform)

func _server_begin_edit(rel_path: String) -> void:
	if _editable_node(rel_path) == null:
		return
	_apply_editing.rpc(rel_path, true)

@rpc("authority", "call_local", "reliable")
func _apply_editing(rel_path: String, editing: bool) -> void:
	var node := _node(rel_path)
	if node != null and "use_collision" in node:
		node.use_collision = not editing

@rpc("authority", "call_local", "unreliable")
func _apply_transform(rel_path: String, xform: Transform3D) -> void:
	var node := _node(rel_path)
	if node != null:
		node.global_transform = xform

@rpc("authority", "call_local", "reliable")
func _apply_commit(rel_path: String, xform: Transform3D) -> void:
	var node := _node(rel_path)
	if node != null:
		node.global_transform = xform
		if "use_collision" in node:
			node.use_collision = true
	_record_override(current_map_path(), rel_path, xform)

# The server only honours edits while creative is allowed (dev build), so a non-dev host can't
# have its layout rewritten by a peer.
func _sender_ok() -> bool:
	return multiplayer.is_server() and creative_allowed()

# --- Layout overrides ------------------------------------------------------

func _record_override(map_path: String, rel_path: String, xform: Transform3D) -> void:
	if map_path == "":
		return
	var edits: Dictionary = _overrides.get(map_path, {})
	edits[rel_path] = xform
	_overrides[map_path] = edits

# Re-apply saved edits whenever a map finishes loading. The host pushes them to every peer; a
# no-peer boot (the editor lobby preview) applies them directly. Clients receive the host's
# commits and do nothing here.
func notify_map_loaded(map_path: String) -> void:
	var edits: Dictionary = _overrides.get(map_path, {})
	if edits.is_empty():
		return
	if not multiplayer.has_multiplayer_peer():
		for rel in edits:
			_apply_commit(rel, edits[rel])
	elif multiplayer.is_server():
		for rel in edits:
			_apply_commit.rpc(rel, edits[rel])

# Catch a late joiner up to the current layout (their Map is loaded just before this).
func send_overrides_to(peer_id: int, map_path: String) -> void:
	if not multiplayer.is_server():
		return
	var edits: Dictionary = _overrides.get(map_path, {})
	for rel in edits:
		_apply_commit.rpc_id(peer_id, rel, edits[rel])

# --- Persistence -----------------------------------------------------------

# Write the current map's edits to user://, so "in-game" reloads of that map show them. Returns
# "" on success or a player-facing error.
func save_layout() -> String:
	var map_path := current_map_path()
	if map_path == "":
		return "No map loaded."
	_ensure_dir(OVERRIDE_DIR)
	var edits: Dictionary = _overrides.get(map_path, {})
	var serial := {}
	for rel in edits:
		serial[rel] = var_to_str(edits[rel])
	var payload := {"map": map_path, "edits": serial}
	var f := FileAccess.open(_override_file(map_path), FileAccess.WRITE)
	if f == null:
		return "Couldn't write the layout file."
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()
	return ""

func _load_all_overrides() -> void:
	if not DirAccess.dir_exists_absolute(OVERRIDE_DIR):
		return
	for file in DirAccess.get_files_at(OVERRIDE_DIR):
		if not file.ends_with(".json"):
			continue
		var f := FileAccess.open(OVERRIDE_DIR + "/" + file, FileAccess.READ)
		if f == null:
			continue
		var payload = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(payload) != TYPE_DICTIONARY or not payload.has("map"):
			continue
		var edits := {}
		for rel in payload.get("edits", {}):
			var xform = str_to_var(payload["edits"][rel])
			if xform is Transform3D:
				edits[rel] = xform
		if not edits.is_empty():
			_overrides[payload["map"]] = edits

# Pack the live map (with its current edits baked in) into a standalone player map under user://,
# selectable from Map Select for local testing. Re-saving the same name overwrites it.
func save_as_new_map(map_name: String) -> String:
	var clean := _sanitize(map_name)
	if clean == "":
		return "Enter a map name."
	var map := map_node()
	if map == null:
		return "No map loaded."
	var packed := PackedScene.new()
	if packed.pack(map) != OK:
		return "Failed to pack the map."
	_ensure_dir(PLAYER_MAP_DIR)
	if ResourceSaver.save(packed, PLAYER_MAP_DIR + "/" + clean + ".tscn") != OK:
		return "Failed to save the map."
	return ""

# Promote a saved player map into the repo so it can be committed as a real built-in map. Only
# works running from source — res:// is read-only in exported builds.
func add_map_to_build(map_name: String) -> String:
	var clean := _sanitize(map_name)
	if clean == "":
		return "Enter a map name."
	var src := PLAYER_MAP_DIR + "/" + clean + ".tscn"
	if not FileAccess.file_exists(src):
		return "Save it as a new map first."
	var bytes := FileAccess.get_file_as_bytes(src)
	var out := FileAccess.open(BUILT_IN_MAP_DIR + "/" + clean + ".tscn", FileAccess.WRITE)
	if out == null:
		return "Can't write to res:// (only works running from the editor/source)."
	out.store_buffer(bytes)
	out.close()
	return ""

# Player maps saved to user://, shown in Map Select. Each is {name, path}.
func list_player_maps() -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(PLAYER_MAP_DIR):
		return out
	for file in DirAccess.get_files_at(PLAYER_MAP_DIR):
		if file.ends_with(".tscn"):
			out.append({"name": file.get_basename(), "path": PLAYER_MAP_DIR + "/" + file})
	return out

# --- Helpers ---------------------------------------------------------------

func _game_root() -> Node:
	return get_tree().get_first_node_in_group("game_root")

func _override_file(map_path: String) -> String:
	return OVERRIDE_DIR + "/" + map_path.get_file().get_basename() + ".json"

func _ensure_dir(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		DirAccess.make_dir_recursive_absolute(path)

func _sanitize(name: String) -> String:
	return name.strip_edges().validate_filename()
