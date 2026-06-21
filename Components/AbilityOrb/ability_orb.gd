extends Area3D
class_name AbilityOrb

# A floating, glowing orb resting on the floor that permanently grants one movement
# ability (dash or double jump) to the first player who touches it. Mirrors
# InfiniteHeartZone: the grant runs on every peer off body_entered (player bodies
# replicate identically, so the overlap fires the same everywhere), which keeps the
# pickup deterministic with no extra RPCs. Unlike the zone, the grant is permanent —
# we never revoke it on exit — so the ability is kept for the rest of the run.

const SOURCE := &"ability_orb"

enum Ability { DASH, DOUBLE_JUMP }

const COLORS := {
	Ability.DASH: Color(0.25, 0.7, 1.0),
	Ability.DOUBLE_JUMP: Color(0.75, 0.45, 1.0),
}

# Billboard icon (two chevrons for dash, wings for double jump) and the name shown
# above it. The icons are white so the modulate tints them to the ability colour.
const ICONS := {
	Ability.DASH: preload("res://Assets/Textures/UI/ability_dash.svg"),
	Ability.DOUBLE_JUMP: preload("res://Assets/Textures/UI/ability_double_jump.svg"),
}
const NAMES := {
	Ability.DASH: "Dash",
	Ability.DOUBLE_JUMP: "Double Jump",
}

# How close the local player must be for the floating name to fade in.
const NAME_SHOW_DISTANCE := 6.0
const NAME_FADE_SPEED := 6.0

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

func _ready() -> void:
	_base_y = _bob.position.y
	body_entered.connect(_on_body_entered)
	_apply_color()

func _process(delta: float) -> void:
	if _collected:
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
	return Player.ABILITY_DASH if ability == Ability.DASH else Player.ABILITY_DOUBLE_JUMP

func _on_body_entered(body: Node3D) -> void:
	if _collected or not (body is Player):
		return
	_collected = true
	body.set_effect(_effect_id(), true, SOURCE)
	_consume()

# Tint the core, glow and floor ring to the ability's colour so the orb reads at a
# glance and matches the matching container in the stamina bar.
func _apply_color() -> void:
	var col: Color = COLORS[ability]
	_light.light_color = col
	_core.material_override = _emissive(col, 0.9)
	_ring.material_override = _emissive(col, 0.7)
	_icon.texture = ICONS[ability]
	# Push the tint past white (HDR) so the billboard icon reads as glowing like the core.
	_icon.modulate = col * 1.6
	_name_label.text = NAMES[ability]
	_name_label.modulate = Color(col.r, col.g, col.b, 0.0)

func _emissive(col: Color, alpha: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(col.r, col.g, col.b, alpha)
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 2.5
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if alpha < 1.0 else BaseMaterial3D.TRANSPARENCY_DISABLED
	return mat

# Hide the orb once taken. Kept (not freed) so the deterministic overlap can't re-fire
# a grant, and so any late body_entered on another peer still finds it inert.
func _consume() -> void:
	monitoring = false
	_bob.visible = false
	_ring.visible = false
	_name_label.visible = false
	set_process(false)
