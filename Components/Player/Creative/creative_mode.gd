extends Node3D
class_name CreativeMode

# Authority-local map-building controller, one per player. Toggled with F2 or the pause menu when
# CreativeManager.creative_allowed(). Two tools: ghost-fly/spectator (double-tap Space to toggle —
# noclip through walls, double-tap again returns to normal standing physics) and grab/move/rotate of
# any solid body in the map. Every editable body within hands reach wears a translate gizmo
# (CreativeGizmo): grab a coloured arrow to slide it along that world axis, or the center box to move
# it freely welded to the camera (hold RMB + mouse to rotate, wheel for distance). Edits are routed
# through CreativeManager so they replicate and persist; nothing here touches networked state directly.

const GRAB_MIN_DIST := 1.5
# Grabbing reach matches the hands' interaction reach — you have to be close to pick up a body,
# and a held body stays within that reach (fly closer to move things further).
const GRAB_MAX_DIST := Hands.INTERACT_REACH
const GRAB_DIST_STEP := 0.5
const ROTATE_MOUSE_SENS := 0.01  # rad per pixel of mouse motion while holding RMB
const DOUBLE_TAP_MS := 300       # max gap between Space presses to count as a double-tap

# Third-person view. Turning creative on dollies the camera back to TP_DEFAULT_DIST; the wheel
# (when no body is held) pulls it in/out, and scrolling all the way in snaps to first person.
const TP_DEFAULT_DIST := 4.0
const TP_MAX_DIST := 9.0
const TP_DIST_STEP := 0.6        # camera dolly per wheel notch
const TP_FP_SNAP := 0.4          # below this the camera returns to true first person
const TP_ZOOM_DAMP := 12.0       # how fast the camera eases toward the target distance

const GIZMO_SCAN_INTERVAL := 0.2  # how often we re-sweep the map for bodies entering/leaving reach

@export var player: Player
@export var camera: Camera3D

var active := false
var flying := false

var _cam_dist := 0.0         # target dolly distance behind the eye (0 = first person)
var _cam_dist_smooth := 0.0  # eased distance actually applied to the camera

var _held: Node3D = null
var _held_path := ""
var _last_jump_ms := 0     # timestamp of the last Space press, for double-tap detection
# The held body's pose captured in camera space at grab time, so it keeps the exact offset it had
# (no snap-to-crosshair) and rides along as the camera looks/flies. Wheel scales _local_offset.
var _local_offset := Vector3.ZERO
var _local_basis := Basis.IDENTITY
var _highlight: CreativeHighlight  # translucent box on the targeted body (own component)

# One translate gizmo per in-reach editable body, keyed by the body's instance id.
var _gizmos := {}
var _scan_accum := 0.0
# The handle the crosshair is on this frame (its body + which arrow / the center), for grab + outline.
var _hover_node: Node3D = null
var _hover_handle := CreativeGizmo.HANDLE_NONE

# Axis-constrained drag (a coloured arrow): the body slides only along _drag_dir. _drag_anchor is the
# body origin at grab time and _drag_s0 the ray's parameter along that line then, so the grab point
# tracks the crosshair without snapping. _drag_last_s freezes movement if the view lines up with the axis.
var _drag_node: Node3D = null
var _drag_path := ""
var _drag_axis := CreativeGizmo.HANDLE_NONE
var _drag_dir := Vector3.ZERO
var _drag_anchor := Vector3.ZERO
var _drag_s0 := 0.0
var _drag_last_s := 0.0

func _ready() -> void:
	_highlight = CreativeHighlight.new()
	add_child(_highlight)

# Rotate a held body by holding RMB and moving the mouse. Handled in _input (which runs before the
# Head's _unhandled_input) and marked handled, so the camera look is suppressed while rotating.
func _input(event: InputEvent) -> void:
	if not active or not multiplayer.has_multiplayer_peer() or not is_multiplayer_authority():
		return
	if _held == null or Global.is_input_blocked():
		return
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		# Trackball rotate in camera space (the body is welded to the camera frame): horizontal drag
		# spins around screen-up, vertical around screen-right. Combined drags reach any orientation.
		var motion := event as InputEventMouseMotion
		var yaw := -motion.relative.x * ROTATE_MOUSE_SENS
		var pitch := -motion.relative.y * ROTATE_MOUSE_SENS
		_local_basis = (Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch) * _local_basis).orthonormalized()
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if not multiplayer.has_multiplayer_peer() or not is_multiplayer_authority():
		return
	if event.is_action_pressed("creative_toggle"):
		set_active(not active)
		get_viewport().set_input_as_handled()
		return
	# Mouse wheel pushes a held body away / pulls it closer; with nothing held it dollies the
	# third-person camera in toward first person / out behind the player.
	if active and event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if _held != null:
				_local_offset = _scale_reach(_local_offset, -GRAB_DIST_STEP)
			else:
				_zoom_camera(-TP_DIST_STEP)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if _held != null:
				_local_offset = _scale_reach(_local_offset, GRAB_DIST_STEP)
			else:
				_zoom_camera(TP_DIST_STEP)

func _physics_process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or not is_multiplayer_authority():
		return
	if not active:
		return
	_update_camera_distance(delta)
	_update_fly_toggle()
	if Global.is_input_blocked():
		_highlight.target(null)
		_clear_hover()
		return
	_refresh_gizmos(delta)
	if _held != null:
		_update_held(delta)
		_highlight.target(_held)
	elif _drag_node != null:
		_update_axis_drag()
		_highlight.target(_drag_node)
	else:
		_update_hover()
		_highlight.target(_hover_node)
	_handle_grab_input()

# --- Toggle ----------------------------------------------------------------

func set_active(value: bool) -> void:
	if value == active:
		return
	if value and not CreativeManager.creative_allowed():
		return
	active = value
	if active:
		# Pop out to third person, easing from the eye so the pull-back is visible.
		_cam_dist = TP_DEFAULT_DIST
		_cam_dist_smooth = 0.0
	else:
		_stop_fly()
		_drop()
		_end_axis_drag()
		_clear_gizmos()
		_highlight.clear()
		_cam_dist = 0.0
		_cam_dist_smooth = 0.0
		camera.position = Vector3.ZERO
	HUD.set_creative(active)

# --- Third-person camera ---------------------------------------------------

# Step the dolly distance by `delta` (wheel notch). Pulling in past the snap threshold returns
# to a true first-person eye; pushing out is capped so the camera stays near the player.
func _zoom_camera(delta: float) -> void:
	_cam_dist = clampf(_cam_dist + delta, 0.0, TP_MAX_DIST)
	if _cam_dist < TP_FP_SNAP:
		_cam_dist = 0.0

# Dolly the camera straight back along its own view ray (yaw is on Head, pitch on the camera),
# so the eye point stays the pivot and the player body sits centred ahead of the camera.
func _update_camera_distance(delta: float) -> void:
	_cam_dist_smooth = lerpf(_cam_dist_smooth, _cam_dist, clampf(delta * TP_ZOOM_DAMP, 0.0, 1.0))
	if _cam_dist_smooth < 0.001:
		camera.position = Vector3.ZERO
		return
	var pitch := camera.rotation.x
	var forward := Vector3(0.0, sin(pitch), -cos(pitch))
	camera.position = -forward * _cam_dist_smooth

# --- Ghost fly (spectator) -------------------------------------------------

# Double-tap Space to toggle ghost/spectator flight on or off.
func _update_fly_toggle() -> void:
	if Global.is_input_blocked():
		return
	if not Input.is_action_just_pressed("jump"):
		return
	var now := Time.get_ticks_msec()
	if now - _last_jump_ms <= DOUBLE_TAP_MS:
		_last_jump_ms = 0
		if flying:
			_stop_fly()
		else:
			_start_fly()
	else:
		_last_jump_ms = now

func _start_fly() -> void:
	flying = true
	player.creative_flying = true
	player.collision_shape.disabled = true

func _stop_fly() -> void:
	if not flying:
		return
	flying = false
	player.creative_flying = false
	player.collision_shape.disabled = false

# --- Grab / move / rotate --------------------------------------------------

# Grab on press: the center handle (or a body face, via the raycast fallback) is a free move; a
# coloured arrow starts an axis-constrained slide. Release commits whichever is active.
func _handle_grab_input() -> void:
	if Input.is_action_just_pressed("interaction"):
		if _held == null and _drag_node == null and _hover_node != null:
			if _hover_handle == CreativeGizmo.HANDLE_CENTER:
				_grab(_hover_node)
			else:
				_begin_axis_drag(_hover_node, _hover_handle)
	elif Input.is_action_just_released("interaction"):
		if _held != null:
			_drop()
		elif _drag_node != null:
			_end_axis_drag()

func _grab(node: Node3D) -> void:
	_held = node
	_held_path = _rel_path(node)
	if _held_path == "":
		_held = null
		return
	# Capture the body's current pose relative to the camera — this is what makes it move with the
	# view rather than snapping its centre onto the crosshair.
	var cam := camera.global_transform
	_local_offset = cam.affine_inverse() * node.global_position
	_local_basis = cam.basis.inverse() * node.global_transform.basis
	CreativeManager.begin_edit(_held_path)

func _update_held(_delta: float) -> void:
	if not is_instance_valid(_held):
		_held = null
		return
	# Re-project the captured camera-space pose (position + orientation, the latter spun by RMB +
	# mouse in _input) through the live camera.
	var cam := camera.global_transform
	var pos := cam * _local_offset
	var basis := cam.basis * _local_basis
	var xform := Transform3D(basis, pos)
	_held.global_transform = xform  # apply locally for responsiveness; server echoes to all peers
	CreativeManager.stream_transform(_held_path, xform)

# Scale a camera-space offset along its own line by `delta`, clamped to the grab reach.
func _scale_reach(offset: Vector3, delta: float) -> Vector3:
	var dist := offset.length()
	if dist < 0.001:
		return offset
	return offset * (clampf(dist + delta, GRAB_MIN_DIST, GRAB_MAX_DIST) / dist)

func _drop() -> void:
	var node := _held
	var path := _held_path
	_held = null
	_held_path = ""
	if not is_instance_valid(node):
		return
	CreativeManager.commit_transform(path, node.global_transform)

# --- Gizmos ----------------------------------------------------------------

# Keep a gizmo on every editable body in reach: re-sweep the map periodically (cheap dev tool), but
# reposition the live gizmos and prune dead ones every frame so they ride moving bodies smoothly.
func _refresh_gizmos(delta: float) -> void:
	_scan_accum -= delta
	if _scan_accum <= 0.0:
		_scan_accum = GIZMO_SCAN_INTERVAL
		_rescan_gizmos()
	for id in _gizmos.keys():
		var g: CreativeGizmo = _gizmos[id]
		if not is_instance_valid(g) or not g.has_valid_target():
			if is_instance_valid(g):
				g.queue_free()
			_gizmos.erase(id)
		else:
			g.update_placement()

func _rescan_gizmos() -> void:
	var wanted := {}
	for node in _editables_in_range():
		wanted[node.get_instance_id()] = node
	# The body being moved keeps its gizmo even if the drag carries it out of reach.
	for n in [_held, _drag_node]:
		if is_instance_valid(n):
			wanted[n.get_instance_id()] = n
	for id in _gizmos.keys():
		if not wanted.has(id):
			if is_instance_valid(_gizmos[id]):
				_gizmos[id].queue_free()
			_gizmos.erase(id)
	for id in wanted:
		if not _gizmos.has(id) or not is_instance_valid(_gizmos[id]):
			var g := CreativeGizmo.new()
			add_child(g)
			g.attach(wanted[id])
			_gizmos[id] = g

func _clear_gizmos() -> void:
	for id in _gizmos:
		if is_instance_valid(_gizmos[id]):
			_gizmos[id].queue_free()
	_gizmos.clear()
	_clear_hover()

# Editable bodies a gizmo should show on: close to the player (measured from the eye/hand root, not
# the dolly-able camera) and in front of where the hand is aiming. Same resolution as a ray grab
# (instanced scene roots move as one piece; loose CSG/bodies move alone; balls are skipped).
func _editables_in_range() -> Array:
	var out: Array = []
	var map := CreativeManager.map_node()
	if map == null:
		return out
	var origin := player.head.global_position
	var fwd := -camera.global_transform.basis.z
	var seen := {}
	for n in map.find_children("*", "Node3D", true, false):
		if n is Grabbable or not (n is CSGShape3D or n is PhysicsBody3D or n is VisualInstance3D):
			continue
		var target := _editable_target(n)
		if target == null:
			continue
		var id := target.get_instance_id()
		if seen.has(id):
			continue
		seen[id] = true
		if _in_reach(target, origin, fwd):
			out.append(target)
	return out

# Within hands reach of `origin` and in the forward hemisphere (so bodies beside or behind the hand
# get no gizmo). Distance is to the body's nearest bounds point so large bodies count when adjacent.
func _in_reach(node: Node3D, origin: Vector3, fwd: Vector3) -> bool:
	var aabb := CreativeGizmo.local_aabb(node)
	var center: Vector3 = node.global_transform * aabb.get_center()
	var radius := (aabb.size * 0.5).length()
	var to := center - origin
	if to.length() - radius > GRAB_MAX_DIST:
		return false
	return to.dot(fwd) > 0.0

# --- Hover + axis drag -----------------------------------------------------

# Find the handle the crosshair is on across every gizmo (nearest perpendicular gap wins) and light
# it up. If no handle is hit, fall back to a world raycast so aiming at a body face still grabs it.
func _update_hover() -> void:
	_clear_hover()
	var from := camera.global_position
	var dir := -camera.global_transform.basis.z
	var best: CreativeGizmo = null
	var best_handle := CreativeGizmo.HANDLE_NONE
	var best_dist := INF
	for id in _gizmos:
		var g: CreativeGizmo = _gizmos[id]
		var r := g.pick(from, dir)
		if r.handle != CreativeGizmo.HANDLE_NONE and r.dist < best_dist:
			best_dist = r.dist
			best = g
			best_handle = r.handle
	if best != null:
		best.set_hover(best_handle)
		_hover_node = best.target_node()
		_hover_handle = best_handle
		return
	var body := _targeted_editable()
	if body != null:
		_hover_node = body
		_hover_handle = CreativeGizmo.HANDLE_CENTER
		var g: CreativeGizmo = _gizmos.get(body.get_instance_id())
		if is_instance_valid(g):
			g.set_hover(CreativeGizmo.HANDLE_CENTER)

func _clear_hover() -> void:
	_hover_node = null
	_hover_handle = CreativeGizmo.HANDLE_NONE
	for id in _gizmos:
		if is_instance_valid(_gizmos[id]):
			_gizmos[id].set_hover(CreativeGizmo.HANDLE_NONE)

func _begin_axis_drag(node: Node3D, handle: int) -> void:
	_drag_path = _rel_path(node)
	if _drag_path == "":
		return
	_drag_node = node
	_drag_axis = handle
	_drag_dir = _axis_world(handle)
	_drag_anchor = node.global_position
	_drag_s0 = _closest_param(camera.global_position, -camera.global_transform.basis.z, _drag_anchor, _drag_dir, 0.0)
	_drag_last_s = _drag_s0
	CreativeManager.begin_edit(_drag_path)

func _update_axis_drag() -> void:
	if not is_instance_valid(_drag_node):
		_end_axis_drag()
		return
	var from := camera.global_position
	var dir := -camera.global_transform.basis.z
	var s := _closest_param(from, dir, _drag_anchor, _drag_dir, _drag_last_s)
	_drag_last_s = s
	var xform := _drag_node.global_transform
	xform.origin = _drag_anchor + _drag_dir * (s - _drag_s0)
	_drag_node.global_transform = xform
	CreativeManager.stream_transform(_drag_path, xform)

func _end_axis_drag() -> void:
	var node := _drag_node
	var path := _drag_path
	_drag_node = null
	_drag_path = ""
	_drag_axis = CreativeGizmo.HANDLE_NONE
	if not is_instance_valid(node):
		return
	CreativeManager.commit_transform(path, node.global_transform)

func _axis_world(handle: int) -> Vector3:
	match handle:
		CreativeGizmo.HANDLE_X: return Vector3.RIGHT
		CreativeGizmo.HANDLE_Y: return Vector3.UP
		CreativeGizmo.HANDLE_Z: return Vector3.BACK
		_: return Vector3.ZERO

# Parameter along the axis line (anchor P0, unit dir A) of the point nearest the view ray. Returns
# `fallback` when the ray is near-parallel to the axis (the projection is undefined), so the drag
# freezes instead of snapping.
func _closest_param(from: Vector3, dir: Vector3, p0: Vector3, axis: Vector3, fallback: float) -> float:
	var w0 := p0 - from
	var b := axis.dot(dir)
	var denom := 1.0 - b * b
	if absf(denom) < 1e-5:
		return fallback
	return (b * dir.dot(w0) - axis.dot(w0)) / denom

# Map body centred on the crosshair (within hands reach), found by raycasting the world. Any solid
# body in the map can be moved — players live outside the Map subtree so they're never targeted,
# and grabbable balls are skipped so creative editing can't fight their netcode.
func _targeted_editable() -> Node3D:
	var space := player.get_world_3d().direct_space_state
	# Cast from the eye/hand root (not the dolly-able camera) so reach stays relative to the player;
	# the dolly is straight back along this same ray, so it still matches the crosshair.
	var from := player.head.global_position
	var to := from - camera.global_transform.basis.z * GRAB_MAX_DIST
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [player.get_rid()]
	query.collide_with_areas = false
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return null
	return _editable_target(hit.collider)

# Resolve a ray hit to the movable target. If the body belongs to an instanced sub-scene (a base,
# flag, etc. — its root has a scene_file_path), grab that whole scene root so it moves as one piece.
# Otherwise grab the loose body itself (the authored CSG walls). Grabbable balls are never targeted.
func _editable_target(node: Object) -> Node3D:
	var map := CreativeManager.map_node()
	if map == null:
		return null
	var body: Node3D = null
	var scene_root: Node3D = null
	var n := node as Node
	while n != null and n != map:
		if n is Node3D and not (n is Grabbable):
			if body == null and (n is CSGShape3D or n is PhysicsBody3D or n is VisualInstance3D):
				body = n as Node3D
			# Topmost instanced ancestor below Map wins, so nested pieces resolve to their base scene.
			if not (n as Node).scene_file_path.is_empty():
				scene_root = n as Node3D
		n = n.get_parent()
	return scene_root if scene_root != null else body

func _rel_path(node: Node3D) -> String:
	var map := CreativeManager.map_node()
	if map == null:
		return ""
	return str(map.get_path_to(node))
