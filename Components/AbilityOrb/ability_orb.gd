@tool
extends Node3D
class_name AbilityOrb

# A floating orb you interact with to gain an ability. Pick the ability with the `ability`
# export; each maps to a Player effect that's granted (broadcast) on pickup, plus a label
# for the prompt and the name of the visual to show. Single use: taking it consumes the orb
# with a fade-out, broadcast so it vanishes for everyone.
#
# Add an ability by extending the enum + ABILITIES table and adding a visual child under
# Object named to match (e.g. "Bomb"). If no visual matches, every visual is shown so a new
# type is never invisible.

enum Ability { BOMB }

const ABILITIES := {
	Ability.BOMB: {"effect": Player.BOMB_CONTAINER, "label": "Explosion", "visual": "Bomb"},
}

const SOURCE := &"ability_orb"

# Floating-object highlight: rests at its authored scale, swells when you're in range.
const IDLE_SCALE := 1.0
const HIGHLIGHT_SCALE := 1.18
const SCALE_LERP := 12.0

# Quick fade for the billboard prompt as you enter/leave range.
const PROMPT_LERP := 16.0

# Gentle idle bob + slow spin of the object (local visual only).
const BOB_AMPLITUDE := 0.12
const BOB_SPEED := 1.6
const SPIN_SPEED := 1.2

# Consume animation: the orb floats up, shrinks and fades away.
const FADE_TIME := 0.7
const FADE_RISE := 0.8
const FADE_END_SCALE := 0.2
const FADE_SPIN := 6.0

@export var ability: Ability = Ability.BOMB:
	set(value):
		ability = value
		_apply_ability_visual()

@onready var prompt: Label3D = $Prompt
@onready var area: Area3D = $Area3D
@onready var object: Node3D = $Object

var _object_base_y := 0.0
var _object_base_scale := Vector3.ONE
var _bob_time := 0.0

# Set once the orb is taken; stops interaction and runs the fade-out.
var _consumed := false
var _fade_mats: Array[StandardMaterial3D] = []
var _fade_emission: Array[float] = []

func _ready() -> void:
	_apply_ability_visual()
	if Engine.is_editor_hint():
		return
	add_to_group("ability_orb")
	_object_base_y = object.position.y
	_object_base_scale = object.scale
	prompt.modulate.a = 0.0
	prompt.outline_modulate.a = 0.0

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _consumed:
		_fade_prompt(delta, "")
		return

	var near := _local_near()

	# Bob, spin, and swell toward the highlight scale when you're in range.
	_bob_time += delta
	object.position.y = _object_base_y + sin(_bob_time * BOB_SPEED) * BOB_AMPLITUDE
	object.rotate_y(delta * SPIN_SPEED)
	var target: float = HIGHLIGHT_SCALE if near else IDLE_SCALE
	object.scale = object.scale.lerp(_object_base_scale * target, delta * SCALE_LERP)

	_fade_prompt(delta, _prompt_text())

	# Interact to take the ability: grant it and consume the orb, both broadcast so every
	# peer agrees on the effect and sees the orb vanish.
	if near and not Global.is_input_blocked() and Input.is_action_just_pressed("interaction"):
		var p := _local_player()
		var effect: StringName = _info()["effect"]
		if p and not p.has_effect(effect):
			p.set_effect_remote.rpc(effect, true, SOURCE)
			consume.rpc()

func _info() -> Dictionary:
	return ABILITIES[ability]

# Show the visual child whose name matches the ability; hide the others. Falls back to
# showing everything if nothing matches, so a new ability is never invisible.
func _apply_ability_visual() -> void:
	var obj := get_node_or_null("Object")
	if obj == null:
		return
	var want: String = ABILITIES.get(ability, {}).get("visual", "")
	var matched := false
	for child in obj.get_children():
		if child is Node3D and child.name == want:
			matched = true
	for child in obj.get_children():
		if child is Node3D:
			child.visible = (not matched) or child.name == want

# Quick fade for the prompt; keep the last text on screen while it fades out.
func _fade_prompt(delta: float, text: String) -> void:
	if text != "":
		prompt.text = text
	var a := lerpf(prompt.modulate.a, 1.0 if text != "" else 0.0, delta * PROMPT_LERP)
	prompt.modulate.a = a
	prompt.outline_modulate.a = a

# Empty when the prompt shouldn't show; the billboard Label3D renders whatever this returns.
func _prompt_text() -> String:
	if _consumed or not _local_near():
		return ""
	var label: String = _info()["label"]
	var p := _local_player()
	if p and p.has_effect(_info()["effect"]):
		return "%s upgrade active" % label
	return "Interact for the %s upgrade" % label

# Take the orb out of play and play the fade-out on every peer.
@rpc("any_peer", "call_local", "reliable")
func consume() -> void:
	if _consumed:
		return
	_consumed = true
	area.monitoring = false
	_begin_fade()

func _begin_fade() -> void:
	# Switch to per-instance transparent materials so we can fade alpha + emission out.
	for m in _visual_meshes():
		var src := m.get_active_material(0)
		var mat: StandardMaterial3D = src.duplicate() if src is StandardMaterial3D else StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.material_override = mat
		_fade_mats.append(mat)
		_fade_emission.append(mat.emission_energy_multiplier if mat.emission_enabled else 0.0)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_method(_apply_fade, 1.0, 0.0, FADE_TIME).set_ease(Tween.EASE_IN)
	tw.tween_property(object, "scale", _object_base_scale * FADE_END_SCALE, FADE_TIME).set_ease(Tween.EASE_IN)
	tw.tween_property(object, "position:y", _object_base_y + FADE_RISE, FADE_TIME)
	tw.tween_property(object, "rotation:y", object.rotation.y + FADE_SPIN, FADE_TIME)
	tw.chain().tween_callback(func() -> void: object.visible = false)

func _apply_fade(t: float) -> void:
	for i in _fade_mats.size():
		var mat := _fade_mats[i]
		var c := mat.albedo_color
		c.a = t
		mat.albedo_color = c
		if mat.emission_enabled:
			mat.emission_energy_multiplier = _fade_emission[i] * t

# Every MeshInstance3D under the floating object (the visuals fade together).
func _visual_meshes() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [object]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			out.append(n)
		stack.append_array(n.get_children())
	return out

func _local_near() -> bool:
	if _consumed:
		return false
	var p := _local_player()
	return p != null and p in area.get_overlapping_bodies()

func _local_player() -> Player:
	if not multiplayer.has_multiplayer_peer():
		return null
	return get_tree().current_scene.get_node_or_null(str(multiplayer.get_unique_id())) as Player
