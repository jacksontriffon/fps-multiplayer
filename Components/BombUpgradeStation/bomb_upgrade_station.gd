extends Node3D
class_name BombUpgradeStation

# Step into range and interact to gain the explosion upgrade: from then on every dodgeball
# you grab is armed as a live bomb (see Dodgeball / Player.BOMB_CONTAINER). Carrying it
# reserves a stamina "bomb container" the same way each heart does. The floating bomb bobs
# and swells while you're near, and a 3D prompt fades in.

const SOURCE := &"bomb_upgrade_station"

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

@onready var prompt: Label3D = $Prompt
@onready var area: Area3D = $Area3D
@onready var object: Node3D = $Object

var _object_base_y := 0.0
var _object_base_scale := Vector3.ONE
var _bob_time := 0.0

func _ready() -> void:
	add_to_group("bomb_upgrade_station")
	_object_base_y = object.position.y
	_object_base_scale = object.scale
	prompt.modulate.a = 0.0
	prompt.outline_modulate.a = 0.0

func _process(delta: float) -> void:
	var near := _local_near()

	# Bob, spin, and swell toward the highlight scale when you're in range.
	_bob_time += delta
	object.position.y = _object_base_y + sin(_bob_time * BOB_SPEED) * BOB_AMPLITUDE
	object.rotate_y(delta * SPIN_SPEED)
	var target: float = HIGHLIGHT_SCALE if near else IDLE_SCALE
	object.scale = object.scale.lerp(_object_base_scale * target, delta * SCALE_LERP)

	# Quick fade for the prompt; keep the last text on screen while it fades out.
	var text := _prompt_text()
	if text != "":
		prompt.text = text
	var a := lerpf(prompt.modulate.a, 1.0 if text != "" else 0.0, delta * PROMPT_LERP)
	prompt.modulate.a = a
	prompt.outline_modulate.a = a

	# Interact to gain the upgrade. Broadcast so every peer's copy of this player agrees.
	if near and not Global.is_input_blocked() and Input.is_action_just_pressed("interaction"):
		var p := _local_player()
		if p and not p.has_effect(Player.BOMB_CONTAINER):
			p.set_effect_remote.rpc(Player.BOMB_CONTAINER, true, SOURCE)

# Empty when the prompt shouldn't show; the billboard Label3D renders whatever this returns.
func _prompt_text() -> String:
	if not _local_near():
		return ""
	var p := _local_player()
	if p and p.has_effect(Player.BOMB_CONTAINER):
		return "Explosion upgrade active"
	return "Interact for the Explosion upgrade"

func _local_near() -> bool:
	var p := _local_player()
	return p != null and p in area.get_overlapping_bodies()

func _local_player() -> Player:
	if not multiplayer.has_multiplayer_peer():
		return null
	return get_tree().current_scene.get_node_or_null(str(multiplayer.get_unique_id())) as Player
