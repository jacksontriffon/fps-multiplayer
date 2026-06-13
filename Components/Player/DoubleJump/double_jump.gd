extends Node
class_name DoubleJump

# Mid-air jump granted after leaving the ground. Authority-only, gated on
# input-block and alive, and drives the Player body. Reads jumped_from_ground
# so a single press can't spend both the ground jump and an air jump.

const MAX_AIR_JUMPS := 1

@export var player: Player

var _air_jumps := 0

func _physics_process(_delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or not is_multiplayer_authority():
		return
	if player.is_on_floor():
		_air_jumps = MAX_AIR_JUMPS
	if Global.is_input_blocked() or not player.alive:
		return
	if Input.is_action_just_pressed("jump") and not player.is_on_floor() \
			and not player.jumped_from_ground and _air_jumps > 0:
		player.velocity.y = Player.JUMP_VELOCITY
		_air_jumps -= 1
