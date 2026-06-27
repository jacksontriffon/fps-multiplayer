extends Node
class_name DoubleJump

# Mid-air jumps unlocked by AbilityOrbs. Authority-only, gated on input-block and
# controllable (no air jump while stunned or dead), and drives the Player body. Reads
# jumped_from_ground so a single press can't spend both the ground jump and an air jump.
# Double Jump grants one air jump; each Extra Jump (+1 Jump) orb adds another. Each air
# jump drains DOUBLE_JUMP_COST, which Stamina reserves as a container slice in the bar.

const DOUBLE_JUMP_COST := 14.0

@export var player: Player

var _air_jumps := 0

# How many mid-air jumps the player currently owns: double jump plus every extra-jump orb.
func _max_air_jumps() -> int:
	var jumps := 0
	if player.has_effect(Player.ABILITY_DOUBLE_JUMP):
		jumps += 1
	if player.has_effect(Player.ABILITY_EXTRA_JUMP):
		jumps += 1
	return jumps

func _physics_process(_delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or not is_multiplayer_authority():
		return
	var max_jumps := _max_air_jumps()
	if player.is_on_floor():
		_air_jumps = max_jumps
	if Global.is_input_blocked() or not player.controllable():
		return
	if max_jumps <= 0:
		return
	if Input.is_action_just_pressed("jump") and not player.is_on_floor() \
			and not player.jumped_from_ground and _air_jumps > 0 \
			and player.stamina.amount >= DOUBLE_JUMP_COST:
		player.velocity.y = Player.JUMP_VELOCITY
		_air_jumps -= 1
		player.stamina.drain(DOUBLE_JUMP_COST)
