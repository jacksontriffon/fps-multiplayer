extends Area3D
class_name AbilityOrb

# A floating, glowing orb resting on the floor that grants one upgrade — dash, double jump,
# the explosion upgrade, infinite ammo or triple throw — to the first player who touches it.
# Mirrors InfiniteHeartZone: the grant runs on every peer off body_entered (player bodies
# replicate identically, so the overlap fires the same everywhere), which keeps the pickup
# deterministic with no extra RPCs.
#
# Every orb carries a `time_limit` (seconds) that applies to whichever ability it grants. A
# positive limit makes it a timed buff that self-expires on the player; the orb fades out and
# deterministically respawns after RESPAWN_DELAY so it can be grabbed again. A limit of 0 makes
# the grant constant — kept until the match's game mode clears it (by default when a round
# finishes; see MatchManager). Constant orbs stay taken until the round respawns every orb
# (round_respawn), so each round starts orb-less and the abilities can be re-collected.

const SOURCE := &"ability_orb"

# RANDOM is a meta-pick (kept last so the real abilities keep their numeric values): an orb
# set to it rolls one of the concrete abilities below. See `ability`/_roll_ability for how the
# roll stays identical on every peer.
enum Ability { DASH, DOUBLE_JUMP, BOMB, INFINITE_AMMO, TRIPLE_THROW, RANDOM }

const EFFECTS := {
	Ability.DASH: Player.ABILITY_DASH,
	Ability.DOUBLE_JUMP: Player.ABILITY_DOUBLE_JUMP,
	Ability.BOMB: Player.ABILITY_BOMB,
	Ability.INFINITE_AMMO: Player.INFINITE_AMMO,
	Ability.TRIPLE_THROW: Player.TRIPLE_THROW,
}

const COLORS := {
	Ability.DASH: Color(0.25, 0.7, 1.0),
	Ability.DOUBLE_JUMP: Color(0.75, 0.45, 1.0),
	Ability.BOMB: Color(1.0, 0.45, 0.1),
	Ability.INFINITE_AMMO: Color(1.0, 0.82, 0.2),
	Ability.TRIPLE_THROW: Color(0.3, 0.9, 0.45),
}

# Billboard icon (two chevrons for dash, wings for double jump, a bomb for the explosion
# upgrade, an infinity loop for infinite ammo) and the name shown above it. The icons are
# white so modulate tints them.
const ICONS := {
	Ability.DASH: preload("res://Assets/Textures/UI/ability_dash.svg"),
	Ability.DOUBLE_JUMP: preload("res://Assets/Textures/UI/ability_double_jump.svg"),
	Ability.BOMB: preload("res://Assets/Textures/UI/ability_bomb.svg"),
	Ability.INFINITE_AMMO: preload("res://Assets/Textures/UI/ability_infinite.svg"),
	Ability.TRIPLE_THROW: preload("res://Assets/Textures/UI/ability_triple.svg"),
}
const NAMES := {
	Ability.DASH: "Dash",
	Ability.DOUBLE_JUMP: "Double Jump",
	Ability.BOMB: "Explosion",
	Ability.INFINITE_AMMO: "Infinite Ammo",
	Ability.TRIPLE_THROW: "Triple Throw",
}

# How long a timed orb (time_limit > 0) stays gone after a pickup before it deterministically
# pops back, so a buff can be grabbed again without a round reset.
const RESPAWN_DELAY := 15.0

# How close the local player must be for the floating name to fade in.
const NAME_SHOW_DISTANCE := 6.0
const NAME_FADE_SPEED := 6.0

# The configured pick. RANDOM defers the choice to a per-spawn roll (see _resolve_ability);
# anything else is used as-is.
@export var ability: Ability = Ability.DASH

# Seconds the granted ability lasts. 0 = constant: kept until the game mode resets it (by
# default at the end of a round). Any positive value makes it a timed buff that self-expires on
# the player, and the orb respawns RESPAWN_DELAY later. Applies to whichever ability is granted.
@export var time_limit: float = 0.0

# Bob/spin feel for the floating core (purely visual, runs on every peer).
@export var bob_height := 0.18
@export var bob_speed := 2.0
@export var spin_speed := 1.2

@onready var _bob: Node3D = $Bob
@onready var _core: MeshInstance3D = $Bob/Core
@onready var _light: OmniLight3D = $Bob/OmniLight3D
@onready var _ring: MeshInstance3D = $FloorRing
@onready var _icon: Sprite3D = $Bob/Icon
@onready var _name_label: Label3D = $Bob/NameLabel

var _base_y := 0.0
var _t := 0.0
var _name_alpha := 0.0
var _collected := false
var _respawn_left := 0.0
var _roll_count := 0
# The concrete ability in effect (equals `ability`, or a rolled one when that is RANDOM).
var _resolved: Ability = Ability.DASH

func _ready() -> void:
	add_to_group("ability_orbs")
	_base_y = _bob.position.y
	body_entered.connect(_on_body_entered)
	_resolve_ability()
	_apply_color()

# Settle _resolved from `ability`. RANDOM rolls a concrete ability with a seed that is
# identical on every peer but varies per game: the host's match_seed (same for everyone, fresh
# each game), the node path (so sibling orbs differ) and _roll_count (so a timed-buff orb
# re-rolls to something new on each respawn). No per-orb RPCs needed.
func _resolve_ability() -> void:
	if ability != Ability.RANDOM:
		_resolved = ability
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(_match_seed()) + "|" + str(get_path()) + ":" + str(_roll_count))
	_roll_count += 1
	_resolved = (rng.randi() % Ability.RANDOM) as Ability  # RANDOM is last, so this is a real ability

# The host-minted per-game seed (game.gd.match_seed), broadcast to every peer via load_map.
# Walk up to the game root rather than using current_scene/groups: during the initial scene
# instantiation (the authored lobby map) current_scene isn't set yet and the game_root group
# isn't populated, but our ancestors — and their match_seed — already exist. Falls back to 0.
func _match_seed() -> int:
	var n := get_parent()
	while n != null:
		if "match_seed" in n:
			return n.match_seed
		n = n.get_parent()
	return 0

func _process(delta: float) -> void:
	if _collected:
		_tick_respawn(delta)
		return
	_t += delta
	_bob.position.y = _base_y + sin(_t * bob_speed) * bob_height
	_core.rotate_y(delta * spin_speed)  # only the nucleus spins; the billboards stay put
	_update_name(delta)

# Fade the floating name in while the local player stands near the orb. Distance is to
# the local (viewing) player, so each client shows the prompt for its own approach.
func _update_name(delta: float) -> void:
	var near := false
	var player := _local_player()
	if player != null:
		near = global_position.distance_to(player.global_position) <= NAME_SHOW_DISTANCE
	_name_alpha = clampf(_name_alpha + (1.0 if near else -1.0) * NAME_FADE_SPEED * delta, 0.0, 1.0)
	_name_label.visible = _name_alpha > 0.0
	if _name_label.visible:
		_name_label.modulate.a = _name_alpha
		_name_label.outline_modulate.a = _name_alpha * 0.7

func _local_player() -> Player:
	for p in get_tree().get_nodes_in_group("players"):
		if p is Player and p.is_multiplayer_authority():
			return p
	return null

func _effect_id() -> StringName:
	return EFFECTS[_resolved]

func _on_body_entered(body: Node3D) -> void:
	if _collected or not (body is Player):
		return
	_collected = true
	if time_limit > 0.0:
		# Timed buff: grant it (it self-expires on the player) and hide the orb until it respawns.
		body.grant_timed_effect(_effect_id(), time_limit, SOURCE)
		_hide_collected()
		_respawn_left = RESPAWN_DELAY
	else:
		# Constant grant: kept until the round resets it, which also respawns this orb.
		body.set_effect(_effect_id(), true, SOURCE)
		_consume()

# Tint the core, glow and floor ring to the ability's colour so the orb reads at a
# glance and matches the matching container in the stamina bar.
func _apply_color() -> void:
	var col: Color = COLORS[_resolved]
	_light.light_color = col
	_core.material_override = _emissive(col, 0.9)
	_ring.material_override = _emissive(col, 0.7)
	_icon.texture = ICONS[_resolved]
	# Push the tint past white (HDR) so the billboard icon reads as glowing like the core.
	_icon.modulate = col * 1.6
	_name_label.text = NAMES[_resolved]
	_name_label.modulate = Color(col.r, col.g, col.b, 0.0)

func _emissive(col: Color, alpha: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(col.r, col.g, col.b, alpha)
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 2.5
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if alpha < 1.0 else BaseMaterial3D.TRANSPARENCY_DISABLED
	return mat

# Hide the orb's visuals and stop it detecting pickups. Shared by the permanent consume and
# the timed-buff fade-out; only the former also halts processing for good.
func _hide_collected() -> void:
	monitoring = false
	_bob.visible = false
	_ring.visible = false
	_name_label.visible = false

# Take a constant orb. Kept (not freed) so the deterministic overlap can't re-fire a grant, and
# so any late body_entered on another peer still finds it inert. Processing stops until the round
# respawns it (round_respawn re-enables it).
func _consume() -> void:
	_hide_collected()
	set_process(false)

# Server -> every peer at the start of a round (see MatchManager): bring the orb back so its
# ability can be collected again, matching the round wiping every player's upgrades. Re-arms a
# consumed constant orb or a faded-out timed one alike.
@rpc("any_peer", "call_local", "reliable")
func round_respawn() -> void:
	if not (multiplayer.get_remote_sender_id() in [0, 1]):
		return
	_respawn_left = 0.0
	set_process(true)
	_restore()

# Timed-buff orbs only: count down the cooldown (in step on every peer) and pop back.
func _tick_respawn(delta: float) -> void:
	if _respawn_left <= 0.0:
		return
	_respawn_left -= delta
	if _respawn_left <= 0.0:
		_restore()

# Re-arm the orb. monitoring=true re-detects any body still standing on it, re-firing
# body_entered identically on every peer — so a camper just refreshes the buff.
func _restore() -> void:
	_collected = false
	_name_alpha = 0.0
	if ability == Ability.RANDOM:
		_resolve_ability()
		_apply_color()
	_bob.visible = true
	_ring.visible = true
	monitoring = true
