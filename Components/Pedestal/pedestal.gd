@tool
extends Node3D
class_name Pedestal

# Lobby start pedestal: step into range and interact to start the match. The floating
# object bobs and grows while you're near, and a 3D prompt fades in telling you whether a
# match can start yet.
#
# Each pedestal starts a specific game mode (set game_mode in the inspector) and shows the
# matching floating object: team_object, ctf_object or br_object. All are plain Node3D
# exports — drag any 3D node into them to swap the look. @tool so the object swaps in the
# editor the moment you change the mode or the references.

enum GameMode { TEAM, CAPTURE_THE_FLAG, BATTLE_ROYALE }

const MODE_NAMES := {
	GameMode.TEAM: "Team Battle",
	GameMode.CAPTURE_THE_FLAG: "Capture the Flag",
	GameMode.BATTLE_ROYALE: "Battle Royale",
}

# Floating-object highlight: rests at its authored scale, swells when you're in range.
const IDLE_SCALE := 1.0
const HIGHLIGHT_SCALE := 1.18
const SCALE_LERP := 12.0

# Quick fade for the billboard prompt as you enter/leave range.
const PROMPT_LERP := 16.0

# Gentle idle bob of the object (local visual; eased by the sine itself).
const BOB_AMPLITUDE := 0.09
const BOB_SPEED := 1.6

@export var game_mode: GameMode = GameMode.TEAM:
	set(value):
		game_mode = value
		_apply_mode_visuals()

## Floating object shown in Team mode. Drag any 3D node here to swap the look.
@export var team_object: Node3D:
	set(value):
		team_object = value
		_apply_mode_visuals()

## Floating object shown in Capture the Flag mode. Drag any 3D node here to swap the look.
@export var ctf_object: Node3D:
	set(value):
		ctf_object = value
		_apply_mode_visuals()

## Floating object shown in Battle Royale mode. Drag any 3D node here to swap the look.
@export var br_object: Node3D:
	set(value):
		br_object = value
		_apply_mode_visuals()

@onready var prompt: Label3D = $Prompt
@onready var area: Area3D = $Area3D

# The object for the active mode; the other is hidden.
var object: Node3D
var _object_base_y := 0.0
var _object_base_scale := Vector3.ONE
var _bob_time := 0.0

func _ready() -> void:
	_apply_mode_visuals()
	if Engine.is_editor_hint():
		return
	add_to_group("pedestal")
	if object:
		_object_base_y = object.position.y
		_object_base_scale = object.scale
	prompt.modulate.a = 0.0
	prompt.outline_modulate.a = 0.0

# Show the object that matches the mode and hide the others. Null-safe and editor-safe.
func _apply_mode_visuals() -> void:
	match game_mode:
		GameMode.CAPTURE_THE_FLAG:
			object = ctf_object
		GameMode.BATTLE_ROYALE:
			object = br_object
		_:
			object = team_object
	for o in [team_object, ctf_object, br_object]:
		if o:
			o.visible = o == object

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var near := _local_near()
	if object:
		# Bob, and swell toward the highlight scale when you're in range.
		_bob_time += delta
		object.position.y = _object_base_y + sin(_bob_time * BOB_SPEED) * BOB_AMPLITUDE
		var target: float = HIGHLIGHT_SCALE if near else IDLE_SCALE
		object.scale = object.scale.lerp(_object_base_scale * target, delta * SCALE_LERP)

	# Quick fade for the prompt; keep the last text on screen while it fades out.
	var text := prompt_text()
	if text != "":
		prompt.text = text
	# Fade fill and outline together — Label3D renders the outline separately.
	var a := lerpf(prompt.modulate.a, 1.0 if text != "" else 0.0, delta * PROMPT_LERP)
	prompt.modulate.a = a
	prompt.outline_modulate.a = a

	# Interacting opens the lobby menu: a big START for the Classic tournament plus a Customise
	# view (mode, map pick, player list). The match itself starts from there. Open even without
	# enough players so you can see who's waiting — the Start buttons stay disabled until the
	# lobby is full enough.
	if near and not Global.is_input_blocked() and Input.is_action_just_pressed("interaction"):
		MapSelect.open()

# Empty when the prompt shouldn't show; the billboard Label3D renders whatever this returns.
func prompt_text() -> String:
	if MatchManager.state != MatchManager.State.WAITING or not _local_near():
		return ""
	return "Interact to play"

func _local_near() -> bool:
	var p := _local_player()
	return p != null and p in area.get_overlapping_bodies()

func _local_player() -> Node3D:
	if not multiplayer.has_multiplayer_peer():
		return null
	return get_tree().current_scene.get_node_or_null(str(multiplayer.get_unique_id()))
