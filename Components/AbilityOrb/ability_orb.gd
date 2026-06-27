extends Area3D
class_name AbilityOrb

# A floating, glowing orb resting on the floor that grants one upgrade — dash, double jump,
# the explosion upgrade, or a timed infinite-ammo buff — to the first player who touches it.
# Mirrors InfiniteHeartZone: the grant runs on every peer off body_entered (player bodies
# replicate identically, so the overlap fires the same everywhere), which keeps the pickup
# deterministic with no extra RPCs. The ability grants are permanent (kept for the rest of
# the run); a timed grant (see DURATIONS) instead self-expires on the player and the orb
# fades out, then deterministically respawns after RESPAWN_DELAY so it can be grabbed again.

const SOURCE := &"ability_orb"

# RANDOM is a meta-pick (kept last so the real abilities keep their numeric values, and so a
# roll covers the whole HEART..DASH range): an orb set to it rolls one of the concrete
# abilities below. See `ability`/_roll_ability for how the roll stays identical on every peer.
enum Ability { DASH, DOUBLE_JUMP, BOMB, INFINITE_AMMO, TRIPLE_THROW, HEART, RANDOM }

# Stackable abilities grant per-orb (each pickup adds another air jump) rather than as a single
# unlock — see _grant_source. +1 Jump is the only one: one orb double-jumps, a second triples.
const STACKABLE := {
	Ability.DOUBLE_JUMP: true,
}

# Player effects granted by each ability. HEART is absent: it isn't a player effect but a
# server-authoritative heart added to MatchManager.lives (see _collect_heart).
const EFFECTS := {
	Ability.DASH: Player.ABILITY_DASH,
	Ability.DOUBLE_JUMP: Player.ABILITY_DOUBLE_JUMP,
	Ability.BOMB: Player.ABILITY_BOMB,
	Ability.INFINITE_AMMO: Player.INFINITE_AMMO,
	Ability.TRIPLE_THROW: Player.TRIPLE_THROW,
}

const COLORS := {
	Ability.DASH: Color(0.25, 0.7, 1.0),
	Ability.DOUBLE_JUMP: Color(1.0, 0.5, 0.8),
	Ability.BOMB: Color(1.0, 0.45, 0.1),
	Ability.INFINITE_AMMO: Color(1.0, 0.82, 0.2),
	Ability.TRIPLE_THROW: Color(0.3, 0.9, 0.45),
	Ability.HEART: Color(0.95, 0.25, 0.35),
}

# Billboard icon (two chevrons for dash, an up arrow with a plus for the stacking +1 Jump, a
# bomb for the explosion upgrade, an infinity loop for infinite ammo) and the name shown above
# it. The icons are white so modulate tints them.
const ICONS := {
	Ability.DASH: preload("res://Assets/Textures/UI/ability_dash.svg"),
	Ability.DOUBLE_JUMP: preload("res://Assets/Textures/UI/ability_extra_jump.svg"),
	Ability.BOMB: preload("res://Assets/Textures/UI/ability_bomb.svg"),
	Ability.INFINITE_AMMO: preload("res://Assets/Textures/UI/ability_infinite.svg"),
	Ability.TRIPLE_THROW: preload("res://Assets/Textures/UI/ability_triple.svg"),
	Ability.HEART: preload("res://Assets/Textures/UI/ability_heart.svg"),
}
const NAMES := {
	Ability.DASH: "Dash",
	Ability.DOUBLE_JUMP: "+1 Jump",
	Ability.BOMB: "Explosion",
	Ability.INFINITE_AMMO: "Infinite Ammo",
	Ability.TRIPLE_THROW: "Triple Throw",
	Ability.HEART: "+1 Heart",
}

# Abilities listed here are timed buffs (seconds), not permanent unlocks; the orb respawns
# RESPAWN_DELAY seconds after such a pickup. Anything absent is a permanent one-shot grant.
const DURATIONS := {
	Ability.INFINITE_AMMO: Player.INFINITE_AMMO_DURATION,
	Ability.TRIPLE_THROW: Player.TRIPLE_THROW_DURATION,
}
const RESPAWN_DELAY := 15.0

# How close the local player must be for the floating name to fade in.
const NAME_SHOW_DISTANCE := 6.0
const NAME_FADE_SPEED := 6.0

# The configured pick. RANDOM defers the choice to a per-spawn roll (see _resolve_ability);
# anything else is used as-is.
@export var ability: Ability = Ability.DASH

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

# Who granted the effect. A stackable ability uses this orb's node path (identical on every
# peer) so each jump orb is a distinct source and the player's source count is its air-jump
# count; everything else shares SOURCE so a second orb of the same kind doesn't double up.
func _grant_source() -> StringName:
	if STACKABLE.get(_resolved, false):
		return StringName(str(get_path()))
	return SOURCE

func _on_body_entered(body: Node3D) -> void:
	if _collected or not (body is Player):
		return
	if _resolved == Ability.HEART:
		_collect_heart(body)
		return
	_collected = true
	var duration: float = DURATIONS.get(_resolved, 0.0)
	if duration > 0.0:
		# Timed buff: grant it (it self-expires on the player) and hide the orb until it respawns.
		body.grant_timed_effect(_effect_id(), duration, SOURCE)
		_hide_collected()
		_respawn_left = RESPAWN_DELAY
	else:
		body.set_effect(_effect_id(), true, _grant_source())
		_consume()

# Heart pickup: hearts live in MatchManager.lives (server-authoritative), so unlike the
# other grants this one can't run purely off the deterministic overlap. The hide/respawn
# still does — every peer keys it on the replicated match state — but only the picker's own
# client asks the host to add the heart, which then broadcasts the new count. Outside a live
# match there are no hearts to add, so the touch is ignored and the orb stays grabbable.
func _collect_heart(body: Player) -> void:
	if MatchManager.state != MatchManager.State.PLAYING:
		return
	_collected = true
	if body.is_multiplayer_authority():
		if multiplayer.is_server():
			MatchManager.server_add_heart(body.name.to_int())
		else:
			MatchManager.request_add_heart.rpc_id(1)
	_hide_collected()
	_respawn_left = RESPAWN_DELAY

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

# Permanently take the orb. Kept (not freed) so the deterministic overlap can't re-fire a
# grant, and so any late body_entered on another peer still finds it inert.
func _consume() -> void:
	_hide_collected()
	set_process(false)

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
