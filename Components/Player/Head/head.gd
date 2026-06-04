extends Node3D
class_name PlayerHead

# First-person look + the local camera. Only the authority peer drives the mouse,
# but Head.rotation (yaw) and Camera3D.rotation (pitch) are replicated by the
# player's MultiplayerSynchronizer, so remote players visibly look around.

const SENSITIVITY = 0.003
const PITCH_LIMIT = deg_to_rad(60)

@onready var camera: Camera3D = $Camera3D

func _ready() -> void:
	if not is_multiplayer_authority():
		return
	camera.make_current()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * SENSITIVITY)
		camera.rotate_x(-event.relative.y * SENSITIVITY)
		camera.rotation.x = clamp(camera.rotation.x, -PITCH_LIMIT, PITCH_LIMIT)
