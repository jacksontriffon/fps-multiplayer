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
const HIGHLIGHT_GROW := 1.04
const HIGHLIGHT_ALPHA := 0.25      # peak translucency of the highlight box
const HIGHLIGHT_EMISSION := 0.6    # peak emission energy
const HIGHLIGHT_FADE_SPEED := 6.0  # fade in/out rate (alpha per second)

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
var _highlighted: Node3D = null
var _highlight_box: MeshInstance3D
var _highlight_mat: StandardMaterial3D
var _highlight_alpha := 0.0  # eased 0..1: drives the box's translucency so it fades in/out

func _ready() -> void:
	_build_highlight_box()

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
		_set_highlight(null)
		_update_highlight_fade(delta)
		return
	if _held != null:
		_update_held(delta)
		_set_highlight(_held)
	else:
		_set_highlight(_targeted_editable())
	_handle_grab_input()
	_update_highlight_fade(delta)

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
		_clear_highlight_now()
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
	if _held == null and _highlighted != null and Input.is_action_just_pressed("interaction"):
		_grab(_highlighted)
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

# --- Highlight (local visual) ----------------------------------------------

func _build_highlight_box() -> void:
	_highlight_box = MeshInstance3D.new()
	_highlight_box.top_level = true
	_highlight_box.visible = false
	_highlight_box.mesh = BoxMesh.new()
	_highlight_mat = StandardMaterial3D.new()
	_highlight_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_highlight_mat.albedo_color = Color(0.3, 0.8, 1.0, 0.0)
	_highlight_mat.emission_enabled = true
	_highlight_mat.emission = Color(0.3, 0.8, 1.0)
	_highlight_mat.emission_energy_multiplier = 0.0
	_highlight_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_highlight_box.material_override = _highlight_mat
	add_child(_highlight_box)

# Set the current target and snap the box to it. Translucency is driven separately by the fade so
# the box eases in when a body is targeted and out when none is (or it stops being valid).
func _set_highlight(node: Node3D) -> void:
	_highlighted = node
	if node == null or not is_instance_valid(node):
		return
	var aabb := _node_aabb(node)
	(_highlight_box.mesh as BoxMesh).size = aabb.size * HIGHLIGHT_GROW
	var b := node.global_transform.basis.orthonormalized()
	_highlight_box.global_transform = Transform3D(b, node.global_transform * aabb.get_center())

# Ease the box's alpha/emission toward fully-on when a body is targeted, off otherwise; hide it
# once it has faded all the way out.
func _update_highlight_fade(delta: float) -> void:
	var target := 1.0 if (_highlighted != null and is_instance_valid(_highlighted)) else 0.0
	_highlight_alpha = move_toward(_highlight_alpha, target, HIGHLIGHT_FADE_SPEED * delta)
	if _highlight_alpha <= 0.001:
		_highlight_box.visible = false
		return
	_highlight_box.visible = true
	_highlight_mat.albedo_color.a = HIGHLIGHT_ALPHA * _highlight_alpha
	_highlight_mat.emission_energy_multiplier = HIGHLIGHT_EMISSION * _highlight_alpha

# Instant clear (no fade) for leaving creative mode.
func _clear_highlight_now() -> void:
	_highlighted = null
	_highlight_alpha = 0.0
	if _highlight_box != null:
		_highlight_box.visible = false

# Local-space bounds for the highlight box: the node's own AABB if it's visual, otherwise the
# merged bounds of its visual descendants (for bodies whose meshes are children).
func _node_aabb(node: Node3D) -> AABB:
	if node is VisualInstance3D:
		return (node as VisualInstance3D).get_aabb()
	var combined := AABB()
	var has := false
	var inv := node.global_transform.affine_inverse()
	for child in node.find_children("*", "VisualInstance3D", true, false):
		var local := inv * (child as Node3D).global_transform * (child as VisualInstance3D).get_aabb()
		if has:
			combined = combined.merge(local)
		else:
			combined = local
			has = true
	return combined if has else AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
