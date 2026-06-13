extends Node
class_name Stamina

# The player's stamina pool. Sprinting (Player) and winding up a throw (Hands) spend
# it through drain(); it refills here after a short idle. Each action owns its own
# cost constant (SPRINT_DRAIN on Player, CHARGE_DRAIN on Hands).
const MAX := 150.0
const REGEN := 20.0
const REGEN_DELAY := 0.6

@export var player: Player

var amount := MAX
var _regen_delay := 0.0

func has_stamina() -> bool:
	return amount > 0.0

func drain(cost: float) -> void:
	amount = maxf(amount - cost, 0.0)
	_regen_delay = REGEN_DELAY

func refill() -> void:
	amount = MAX
	_regen_delay = 0.0

func _physics_process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or not is_multiplayer_authority():
		return
	# Refill once we've stopped spending it for a moment.
	_regen_delay = maxf(_regen_delay - delta, 0.0)
	if _regen_delay == 0.0 and amount < MAX:
		amount = minf(amount + REGEN * delta, MAX)
