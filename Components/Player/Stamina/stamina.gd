extends Node
class_name Stamina

# The player's stamina pool. Sprinting (Player) and winding up a throw (Hands) spend
# it through drain(); it refills here after a short idle. Each action owns its own
# cost constant (SPRINT_DRAIN on Player, CHARGE_DRAIN on Hands).
#
# The pool (MAX) is carved into by "reservations": each claims a slice, shrinking the usable
# max (capacity()). Hearts are the first source — every heart reserves PER_HEART — so a player
# with fewer hearts has a larger stamina pool. The HUD reads capacity() to size the bar.
const MAX := 150.0
const PER_HEART := 24.0
const REGEN := 20.0
const REGEN_DELAY := 0.6

# Reservation source ids. Add more (debuffs, abilities) and they shrink the pool the same way.
const RES_HEARTS := &"hearts"
# Owned abilities each carve a container slice the width of their cost — the HUD draws it
# as a cell and the player spends from the pool to fire the ability.
const RES_DASH := &"dash"
const RES_DOUBLE_JUMP := &"double_jump"
const RES_BOMB := &"bomb"
# Unlike dash/double-jump, the explosion upgrade doesn't drain per use — carrying it is the
# whole cost, so its container reserves a fixed slice the size of one heart.
const BOMB_COST := PER_HEART
# The infinite-ammo buff reserves a slice scaled by its remaining time: AMMO_MAX_RESERVE at
# pickup, shrinking to nothing as it expires. Capped so a sliver of pool always survives —
# you still need a little stamina to charge a throw with all that free ammo.
const RES_INFINITE_AMMO := &"infinite_ammo"
const AMMO_MAX_RESERVE := 100.0
const AMMO_MIN_CAPACITY := 25.0
# The triple-throw buff reserves a slice the same way: biggest at pickup, shrinking to
# nothing as it expires, capped so a sliver of pool always survives to charge a throw.
const RES_TRIPLE_THROW := &"triple_throw"
const TRIPLE_MAX_RESERVE := 100.0
const TRIPLE_MIN_CAPACITY := 25.0

@export var player: Player

var amount := MAX
var _regen_delay := 0.0

# Reservation source id -> amount of the pool it claims. Keyed by source so several can
# stack without clobbering each other; capacity() is MAX minus their sum.
var _reservations := {}

func has_stamina() -> bool:
	return amount > 0.0

func drain(cost: float) -> void:
	amount = maxf(amount - cost, 0.0)
	_regen_delay = REGEN_DELAY

func refill() -> void:
	_refresh_reservations()
	amount = capacity()
	_regen_delay = 0.0

# Claim part of the pool for a source (0 or less clears it).
func reserve(source: StringName, value: float) -> void:
	if value > 0.0:
		_reservations[source] = value
	else:
		_reservations.erase(source)

# How much a given source currently reserves (0 if none). Read by the HUD to size its cells.
func reserved(source: StringName) -> float:
	return _reservations.get(source, 0.0)

# Usable max: the pool minus everything reserved (never below zero).
func capacity() -> float:
	var reserved := 0.0
	for value in _reservations.values():
		reserved += value
	return maxf(MAX - reserved, 0.0)

# Hearts (and, later, other debuffs) each carve a slice out of the pool, so the usable max
# grows as a player loses hearts. Recomputed each frame from match state: no reservation in
# the lobby (no lives yet), one heart while the infinite-hearts effect is up, and the live
# heart count in any mode with lives (including CTF) so the bar matches the HUD's hearts.
func _refresh_reservations() -> void:
	var hearts := 0
	if player.has_effect(Player.INFINITE_HEARTS):
		hearts = 1
	elif MatchManager.state != MatchManager.State.WAITING:
		hearts = maxi(MatchManager.lives.get(player.name.to_int(), 0), 0)
	reserve(RES_HEARTS, float(hearts) * PER_HEART)
	# Each unlocked ability reserves its own container slice in the bar.
	reserve(RES_DASH, Dash.DASH_COST if player.has_effect(Player.ABILITY_DASH) else 0.0)
	reserve(RES_DOUBLE_JUMP, DoubleJump.DOUBLE_JUMP_COST if player.has_effect(Player.ABILITY_DOUBLE_JUMP) else 0.0)
	reserve(RES_BOMB, BOMB_COST if player.has_effect(Player.ABILITY_BOMB) else 0.0)
	# Infinite ammo: a big slice up front that shrinks with the buff's remaining time. Cleared
	# first so the cap below sees only the other reservations, then capped to leave AMMO_MIN_CAPACITY.
	reserve(RES_INFINITE_AMMO, 0.0)
	if player.has_effect(Player.INFINITE_AMMO) and Player.INFINITE_AMMO_DURATION > 0.0:
		var frac := clampf(player.effect_time_left(Player.INFINITE_AMMO) / Player.INFINITE_AMMO_DURATION, 0.0, 1.0)
		var max_allowed := maxf(capacity() - AMMO_MIN_CAPACITY, 0.0)
		reserve(RES_INFINITE_AMMO, minf(frac * AMMO_MAX_RESERVE, max_allowed))
	# Triple throw: same shrinking slice as infinite ammo, capped against the pool left after it.
	reserve(RES_TRIPLE_THROW, 0.0)
	if player.has_effect(Player.TRIPLE_THROW) and Player.TRIPLE_THROW_DURATION > 0.0:
		var frac := clampf(player.effect_time_left(Player.TRIPLE_THROW) / Player.TRIPLE_THROW_DURATION, 0.0, 1.0)
		var max_allowed := maxf(capacity() - TRIPLE_MIN_CAPACITY, 0.0)
		reserve(RES_TRIPLE_THROW, minf(frac * TRIPLE_MAX_RESERVE, max_allowed))

func _physics_process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or not is_multiplayer_authority():
		return
	# Hearts/debuffs may have changed the pool — clamp to the current max, then refill once
	# we've stopped spending it for a moment.
	_refresh_reservations()
	var cap := capacity()
	amount = minf(amount, cap)
	_regen_delay = maxf(_regen_delay - delta, 0.0)
	if _regen_delay == 0.0 and amount < cap:
		amount = minf(amount + REGEN * delta, cap)
