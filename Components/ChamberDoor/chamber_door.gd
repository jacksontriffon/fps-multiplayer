extends CSGBox3D
class_name ChamberDoor

# Rises while the chamber's ball is off its pedestal; reads only replicated ball
# state (held_by, position), so every peer animates its own copy in sync.

const SPEED := 5.0
const REST_RADIUS := 0.75

@export var ball: Grabbable
@export var open_distance := 4.0

var _closed_y := 0.0
var _rest_position := Vector3.ZERO

func _ready() -> void:
	_closed_y = position.y
	if ball:
		_rest_position = ball.global_position

func _physics_process(delta: float) -> void:
	if ball == null:
		return
	var taken := ball.held_by != 0 or ball.global_position.distance_to(_rest_position) > REST_RADIUS
	var target := _closed_y + open_distance if taken else _closed_y
	position.y = move_toward(position.y, target, SPEED * delta)
