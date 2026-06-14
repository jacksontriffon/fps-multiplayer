extends Node
class_name Crouch

# Hold-to-crouch. The authority reads input and sets player.crouching; that flag
# replicates so every peer shrinks the body (camera, mesh, hitbox) toward the floor.

const BODY_SCALE := 0.6
const HEAD_DROP := 0.5
const POSE_SPEED := 12.0

@export var player: Player
@export var head: Node3D
@export var mesh: MeshInstance3D
@export var collision_shape: CollisionShape3D

var _head_rest := 0.0
var _mesh_rest := 0.0
var _shape_rest := 0.0
var _pose := 0.0

func _ready() -> void:
	_head_rest = head.position.y
	_mesh_rest = mesh.position.y
	_shape_rest = collision_shape.position.y

func _physics_process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	if is_multiplayer_authority():
		player.crouching = not Global.is_input_blocked() and player.controllable() \
				and Input.is_action_pressed("crouch")
	_pose = move_toward(_pose, 1.0 if player.crouching else 0.0, POSE_SPEED * delta)
	_apply_pose()

# Scale the body about the floor origin so the top ducks down while ground contact holds.
func _apply_pose() -> void:
	var s: float = lerpf(1.0, BODY_SCALE, _pose)
	head.position.y = _head_rest - HEAD_DROP * _pose
	mesh.scale.y = s
	mesh.position.y = _mesh_rest * s
	collision_shape.scale.y = s
	collision_shape.position.y = _shape_rest * s
