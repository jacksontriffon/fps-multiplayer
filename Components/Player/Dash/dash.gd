extends Node
class_name Dash

# A quick burst of speed on the controlling peer, paid from the player's stamina
# pool. Pushed through Player.apply_dash, which layers it on top of input velocity
# with a slower decay than knockback so it reads as a lunge even while moving, and
# replicates via the existing position sync with no extra RPCs.

# Ground and air dash at the same strength. These feed Player's dash_vel accumulator,
# so the effective lunge is several times the raw number — tune there and in
# DASH_DECAY / DASH_BLEED for distance. The air value stays separate so it can be
# dialled back down if air dashes ever need reining in.
const DASH_IMPULSE := 3.0
const DASH_IMPULSE_AIR := 3.0
const DASH_COST := 40.0
const DASH_COOLDOWN := 1.2

@export var player: Player
@export var head: Node3D

var _cooldown := 0.0

func _physics_process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or not is_multiplayer_authority():
		return
	_cooldown = maxf(_cooldown - delta, 0.0)
	if Global.is_input_blocked() or not player.controllable():
		return
	if Input.is_action_just_pressed("dash") and _cooldown == 0.0 and player.stamina.amount >= DASH_COST:
		# Burst toward the move input, or our facing direction when standing still.
		var input_dir := Input.get_vector("left", "right", "up", "down")
		var dir := head.transform.basis * Vector3(input_dir.x, 0, input_dir.y)
		if dir == Vector3.ZERO:
			dir = head.transform.basis * Vector3.FORWARD
		dir.y = 0.0
		var impulse := DASH_IMPULSE if player.is_on_floor() else DASH_IMPULSE_AIR
		player.apply_dash(dir.normalized() * impulse)
		player.stamina.drain(DASH_COST)
		_cooldown = DASH_COOLDOWN
