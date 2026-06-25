extends Node3D
class_name CreativeMode

# Authority-local map-building controller, one per player. Toggled with F2 or the pause menu when
# CreativeManager.creative_allowed(). Two tools: ghost-fly/spectator (double-tap Space to toggle —
# noclip through walls, double-tap again returns to normal standing physics) and grab/move/rotate of
# any solid body in the map (LMB grab/hold, hold RMB + mouse to rotate, wheel for distance). Edits
# are routed through CreativeManager so they replicate and persist; nothing here touches networked
# state directly.

const GRAB_MIN_DIST := 1.5
# Grabbing reach matches the hands' interaction reach — you have to be close to pick up a body,
# and a held body stays within that reach (fly closer to move things further).
const GRAB_MAX_DIST := Hands.INTERACT_REACH
const GRAB_DIST_STEP := 0.5
const ROTATE_MOUSE_SENS := 0.01  # rad per pixel of mouse motion while holding RMB
const DOUBLE_TAP_MS := 300       # max gap between Space presses to count as a double-tap

@export var player: Player
@export var camera: Camera3D

var active := false
var flying := false

var _held: Node3D = null
var _held_path := ""
var _last_jump_ms := 0     # timestamp of the last Space press, for double-tap detection
# The held body's pose captured in camera space at grab time, so it keeps the exact offset it had
# (no snap-to-crosshair) and rides along as the camera looks/flies. Wheel scales _local_offset.
var _local_offset := Vector3.ZERO
var _local_basis := Basis.IDENTITY
var _target: Node3D = null         # editable body under the crosshair, for grab + highlight
var _highlight: CreativeHighlight  # translucent box on the targeted body (own component)

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
	# Mouse wheel pushes the held body away / pulls it closer, keeping it within reach.
	if active and _held != null and event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_local_offset = _scale_reach(_local_offset, -GRAB_DIST_STEP)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_local_offset = _scale_reach(_local_offset, GRAB_DIST_STEP)

func _physics_process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or not is_multiplayer_authority():
		return
	if not active:
		return
	_update_fly_toggle()
	if Global.is_input_blocked():
		_highlight.target(null)
		return
	if _held != null:
		_update_held(delta)
		_highlight.target(_held)
	else:
		_target = _targeted_editable()
		_highlight.target(_target)
	_handle_grab_input()

# --- Toggle ----------------------------------------------------------------

func set_active(value: bool) -> void:
	if value == active:
		return
	if value and not CreativeManager.creative_allowed():
		return
	active = value
	if not active:
		_stop_fly()
		_drop()
		_target = null
		_highlight.clear()
	HUD.set_creative(active)

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

func _handle_grab_input() -> void:
	if _held == null and _target != null and Input.is_action_just_pressed("interaction"):
		_grab(_target)
	elif _held != null and Input.is_action_just_released("interaction"):
		_drop()

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

# Map body centred on the crosshair (within hands reach), found by raycasting the world. Any solid
# body in the map can be moved — players live outside the Map subtree so they're never targeted,
# and grabbable balls are skipped so creative editing can't fight their netcode.
func _targeted_editable() -> Node3D:
	var space := player.get_world_3d().direct_space_state
	var from := camera.global_position
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
