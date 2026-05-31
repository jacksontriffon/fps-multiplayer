extends Node3D
class_name Hands

var grabbable_objects: Array[Grabbable] = []
var grabbed_object: Grabbable = null
var grabbing := false

@onready var right_hand_marker := $MeshInstance3D/RightHandMarker

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("interaction"):
		grab_nearest_object()

func grab_nearest_object() -> void:
	grab_object(get_nearest_object())

func get_nearest_object() -> Grabbable:
	var nearest_object: Grabbable = null
	for object in grabbable_objects:
		if not nearest_object:
			nearest_object = object
			continue
		if object.global_position.distance_squared_to(self.global_position) < \
		nearest_object.global_position.distance_squared_to(self.global_position):
			nearest_object = object
	return nearest_object

func grab_object(object: Grabbable) -> void:
	object.reparent(self)
	object.global_position = right_hand_marker.global_position
	
	await get_tree().create_timer(0.1).timeout
	grabbed_object = object
	grabbing = true
	grabbable_objects.erase(object)

func _on_grabbable_area_body_entered(body: Node3D) -> void:
	if body is Grabbable:
		grabbable_objects.push_back(body)
		update_nearest_object_highlight()

func update_nearest_object_highlight() -> void:
	get_nearest_object().toggle_highlight(true)

func _on_grabbable_area_body_exited(body: Node3D) -> void:
	grabbable_objects.erase(body)
	body.toggle_highlight(false)
	# unhighlight if nearest object
	pass
