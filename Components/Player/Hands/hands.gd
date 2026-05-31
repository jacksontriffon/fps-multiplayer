extends Node3D
class_name Hands

@export var camera: Camera3D

const THROW_FORCE = 15

var grabbable_objects: Array[Grabbable] = []
var highlighted: Grabbable = null 
var grabbed_object: Grabbable = null

@onready var right_hand_marker := $MeshInstance3D/RightHandMarker

func _physics_process(_delta: float) -> void:
	update_highlight()

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("interaction"):
		if not grabbed_object:
			grab_object(highlighted)
		else:
			throw()

# --- Detection ---
func _on_grabbable_area_body_entered(body: Node3D) -> void:
	if body is Grabbable:
		grabbable_objects.push_back(body)

func _on_grabbable_area_body_exited(body: Node3D) -> void:
	if body is Grabbable:
		grabbable_objects.erase(body)

# --- Highlight ---
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

# --- Grab ---
# freeze the body and stick it to the hand marker
func grab_object(object: Grabbable) -> void:
	if not object:
		return
	grabbable_objects.erase(object)
	object.toggle_highlight(false)
	highlighted = null

	object.freeze = true
#	Prevent player from colliding with ball while holding it
	object.collision_layer = 0
	object.collision_mask = 0
	object.reparent(right_hand_marker)  
	object.position = Vector3.ZERO
	grabbed_object = object

# --- Throw ---
func throw() -> void:
	if not grabbed_object:
		return
	
	var ball := grabbed_object
	# put it back in the world so it isn't dragged around by the hand
	grabbed_object.reparent(get_tree().current_scene)
	
	# undo the "held" state
	grabbed_object.freeze = false
	grabbed_object.collision_layer = 1
	grabbed_object.collision_mask = 1
	
	# aim down the camera and throw
	var direction = -camera.global_transform.basis.z
	ball.apply_central_impulse(direction * THROW_FORCE)
	grabbed_object = null
