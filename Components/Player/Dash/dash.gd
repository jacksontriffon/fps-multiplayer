extends Node
class_name Dash

# A quick burst of speed on the controlling peer, paid from the player's stamina
# pool. Applied as self-knockback (Player.apply_knockback) so it layers on top of
# input velocity and decays like other impulses, and replicates via the existing
# position sync with no extra RPCs.

const DASH_IMPULSE := 4.0
const DASH_COST := 40.0
const DASH_COOLDOWN := 1.2

@export var player: Player
@export var head: Node3D

var _cooldown := 0.0

func _physics_process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or not is_multiplayer_authority():
		return
	_cooldown = maxf(_cooldown - delta, 0.0)
	if Global.is_input_blocked() or not player.alive:
		return
	if Input.is_action_just_pressed("dash") and _cooldown == 0.0 and player.stamina >= DASH_COST:
		# Burst toward the move input, or our facing direction when standing still.
		var input_dir := Input.get_vector("left", "right", "up", "down")
		var dir := head.transform.basis * Vector3(input_dir.x, 0, input_dir.y)
		if dir == Vector3.ZERO:
			dir = head.transform.basis * Vector3.FORWARD
		dir.y = 0.0
		player.apply_knockback(dir.normalized() * DASH_IMPULSE)
		player.drain_stamina(DASH_COST)
		_cooldown = DASH_COOLDOWN
