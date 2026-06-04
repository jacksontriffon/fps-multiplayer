extends Node3D
class_name Hands

# Detection and highlighting are local to the controlling (authority) peer.
# Grab/throw are triggered by the authority but executed on every peer via RPC,
# so the held ball — parented to this hand, whose transform is replicated by the
# player's MultiplayerSynchronizer — shows up correctly for everyone.

@export var camera: Camera3D

const THROW_FORCE = 15

var grabbable_objects: Array[Grabbable] = []
var highlighted: Grabbable = null
var grabbed_object: Grabbable = null

@onready var right_hand_marker := $MeshInstance3D/RightHandMarker

func _physics_process(_delta: float) -> void:
	if not is_multiplayer_authority():
		return
	update_highlight()

func _input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if event.is_action_pressed("interaction"):
		if not grabbed_object:
			if highlighted:
				grab.rpc(highlighted.get_path())
		else:
			# Aim down the (replicated) camera and let every peer throw the same way.
			throw.rpc(-camera.global_transform.basis.z)

# --- Networked actions -----------------------------------------------------
# call_local => the authority runs them too, so all peers stay consistent.

@rpc("authority", "call_local", "reliable")
func grab(object_path: NodePath) -> void:
	var object := get_node_or_null(object_path) as Grabbable
	if object:
		_attach(object)

@rpc("authority", "call_local", "reliable")
func throw(direction: Vector3) -> void:
	if grabbed_object:
		_release(grabbed_object, direction)

# --- Detection -------------------------------------------------------------
func _on_grabbable_area_body_entered(body: Node3D) -> void:
	if body is Grabbable:
		grabbable_objects.push_back(body)

func _on_grabbable_area_body_exited(body: Node3D) -> void:
	if body is Grabbable:
		grabbable_objects.erase(body)

func _on_grabbable_area_area_entered(_area: Area3D) -> void:
	pass

func _on_grabbable_area_area_exited(_area: Area3D) -> void:
	pass

# --- Highlight -------------------------------------------------------------
func update_highlight() -> void:
	var nearest := get_nearest_grabbable_object()
	if nearest == highlighted:
		return
	if highlighted:
		highlighted.toggle_highlight(false)
	if nearest:
		nearest.toggle_highlight(true)
	highlighted = nearest

func get_nearest_grabbable_object() -> Grabbable:
	var nearest: Grabbable = null
	var nearest_dist := INF
	for object in grabbable_objects:
		var d := object.global_position.distance_squared_to(global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = object
	return nearest

# --- Grab: freeze the body and stick it to the hand marker -----------------
func _attach(object: Grabbable) -> void:
	grabbable_objects.erase(object)
	object.toggle_highlight(false)
	if highlighted == object:
		highlighted = null

	object.freeze = true
	# Prevent player from colliding with ball while holding it
	object.collision_layer = 0
	object.collision_mask = 0
	object.reparent(right_hand_marker)
	object.position = Vector3.ZERO
	grabbed_object = object

# --- Throw -----------------------------------------------------------------
func _release(object: Grabbable, direction: Vector3) -> void:
	# put it back in the world so it isn't dragged around by the hand
	object.reparent(get_tree().current_scene)

	# undo the "held" state
	object.freeze = false
	object.collision_layer = 1
	object.collision_mask = 1

	object.apply_central_impulse(direction * THROW_FORCE)
	grabbed_object = null
