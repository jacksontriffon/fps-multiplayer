extends Node
class_name DoubleJump

# Mid-air jump unlocked by an AbilityOrb. Authority-only, gated on input-block and
# controllable (no air jump while stunned or dead), and drives the Player body. Reads
# jumped_from_ground so a single press can't spend both the ground jump and an air jump.
# Each air jump drains DOUBLE_JUMP_COST, which Stamina reserves as this ability's
# container slice in the bar.

const MAX_AIR_JUMPS := 1
const DOUBLE_JUMP_COST := 14.0

@export var player: Player

var _air_jumps := 0

func _physics_process(_delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or not is_multiplayer_authority():
		return
	if player.is_on_floor():
		_air_jumps = MAX_AIR_JUMPS
	if Global.is_input_blocked() or not player.controllable():
		return
	if not player.has_effect(Player.ABILITY_DOUBLE_JUMP):
		return
	if Input.is_action_just_pressed("jump") and not player.is_on_floor() \
			and not player.jumped_from_ground and _air_jumps > 0 \
			and player.stamina.amount >= DOUBLE_JUMP_COST:
		player.velocity.y = Player.JUMP_VELOCITY
		_air_jumps -= 1
		player.stamina.drain(DOUBLE_JUMP_COST)
