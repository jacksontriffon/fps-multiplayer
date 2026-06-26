extends Node3D
class_name CreativeMode

# Authority-local map-building controller, one per player. Toggled with F2 or the pause menu when
# CreativeManager.creative_allowed(). Two tools: ghost-fly/spectator (double-tap Space to toggle —
# noclip through walls, double-tap again returns to normal standing physics) and grab/move/rotate of
# any solid body in the map. The body the crosshair is on (same raycast as the highlight) wears a
# translate gizmo (CreativeGizmo): grab a coloured arrow to slide it along that world axis, or the
# center box to move it freely welded to the camera (hold RMB + mouse to rotate, wheel for distance).
# Edits are routed through CreativeManager so they replicate and persist; nothing here touches
# networked state directly.

const GRAB_MIN_DIST := 1.5
# Grabbing reach matches the hands' interaction reach — you have to be close to pick up a body,
# and a held body stays within that reach (fly closer to move things further).
const GRAB_MAX_DIST := Hands.INTERACT_REACH
const GRAB_DIST_STEP := 0.5
const ROTATE_MOUSE_SENS := 0.01  # rad per pixel of mouse motion while holding RMB
const DOUBLE_TAP_MS := 300       # max gap between Space presses to count as a double-tap

# Third-person view. Creative starts in first person; the wheel (when no body is held) dollies the
# camera out behind the player and back, snapping to first person once pulled all the way in.
const TP_MAX_DIST := 9.0
const TP_DIST_STEP := 0.6        # camera dolly per wheel notch
const TP_FP_SNAP := 0.4          # below this the camera returns to true first person
const TP_ZOOM_DAMP := 12.0       # how fast the camera eases toward the target distance

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

# A single translate gizmo on the body the crosshair is targeting (_focus), rebuilt when the target
# changes. _hover_handle is which part of it the crosshair is on this frame, for grab + outline.
var _gizmo: CreativeGizmo = null
var _focus: Node3D = null
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
		_set_focus(null)
		_hover_handle = CreativeGizmo.HANDLE_NONE
		return
	if _held != null:
		_update_held(delta)
		_highlight.target(_held)
		_place_gizmo(CreativeGizmo.HANDLE_CENTER)
	elif _drag_node != null:
		_update_axis_drag()
		_highlight.target(_drag_node)
		_place_gizmo(_drag_axis)
	else:
		_update_focus()
		_highlight.target(_focus)
	_handle_grab_input()

# --- Toggle ----------------------------------------------------------------

func set_active(value: bool) -> void:
	if value == active:
		return
	if value and not CreativeManager.creative_allowed():
		return
	active = value
	if active:
		# Stay in first person on entry; the wheel can dolly out to third person from here.
		_cam_dist = 0.0
		_cam_dist_smooth = 0.0
	else:
		_stop_fly()
		_drop()
		_end_axis_drag()
		_set_focus(null)
		_hover_handle = CreativeGizmo.HANDLE_NONE
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
		if _held == null and _drag_node == null and _focus != null:
			if _hover_handle == CreativeGizmo.HANDLE_CENTER:
				_grab(_focus)
			else:
				_begin_axis_drag(_focus, _hover_handle)
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

# --- Gizmo (single, on the targeted body) ----------------------------------

# Point the gizmo at the body under the crosshair (the same raycast the highlight uses) and light up
# the handle being aimed at. Once a gizmo is up, aiming at one of its arms keeps it focused even if
# the ray slips off the body's silhouette, so the arrows stay grabbable.
func _update_focus() -> void:
	var from := camera.global_position
	var dir := -camera.global_transform.basis.z
	var on_arm := CreativeGizmo.HANDLE_NONE
	if _gizmo != null and is_instance_valid(_gizmo) and is_instance_valid(_focus):
		_gizmo.update_placement(player.head.global_position)
		on_arm = _gizmo.pick(from, dir).handle
	var body := _targeted_editable()
	if body != null:
		_set_focus(body)
	elif on_arm == CreativeGizmo.HANDLE_NONE:
		_set_focus(null)
	if _focus == null:
		_hover_handle = CreativeGizmo.HANDLE_NONE
		return
	_gizmo.update_placement(player.head.global_position)
	var handle: int = _gizmo.pick(from, dir).handle
	if handle == CreativeGizmo.HANDLE_NONE:
		handle = CreativeGizmo.HANDLE_CENTER  # on the body but off the arms → center grab
	_hover_handle = handle
	_gizmo.set_hover(handle)

# Swap the gizmo onto `node` (rebuilding it to that body's size), or tear it down for null.
func _set_focus(node: Node3D) -> void:
	if node == _focus and (node == null or is_instance_valid(_gizmo)):
		return
	_focus = node
	if _gizmo != null and is_instance_valid(_gizmo):
		_gizmo.queue_free()
	_gizmo = null
	if node != null:
		_gizmo = CreativeGizmo.new()
		add_child(_gizmo)
		_gizmo.attach(node)

# Keep the live gizmo riding its body and highlighting `handle` (used while holding / axis-dragging).
func _place_gizmo(handle: int) -> void:
	if _gizmo == null or not is_instance_valid(_gizmo):
		return
	_gizmo.update_placement(player.head.global_position)
	_gizmo.set_hover(handle)

# --- Axis drag -------------------------------------------------------------

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
