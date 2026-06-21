@tool
extends Node3D
class_name Pedestal

# Lobby start pedestal: aim at it and click to start the match. The floating object bobs
# and grows while you have it on your crosshair (inside your interaction reach); the HUD
# shows the interaction prompt under the crosshair while it's targeted.
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

# The object for the active mode; the other is hidden.
var object: Node3D
var _object_base_y := 0.0
var _object_base_scale := Vector3.ONE
var _bob_time := 0.0

# Set by the local player's Hands when this pedestal is the crosshair-targeted interactable.
var _targeted := false

func _ready() -> void:
	_apply_mode_visuals()
	if Engine.is_editor_hint():
		return
	add_to_group("pedestal")
	# Picked up by the player's interaction area (Hands.GrabbableArea) and clicked via the crosshair.
	add_to_group("interactable")
	if object:
		_object_base_y = object.position.y
		_object_base_scale = object.scale

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
	if object:
		# Bob, and swell toward the highlight scale while you're aiming at it.
		_bob_time += delta
		object.position.y = _object_base_y + sin(_bob_time * BOB_SPEED) * BOB_AMPLITUDE
		var target: float = HIGHLIGHT_SCALE if _targeted else IDLE_SCALE
		object.scale = object.scale.lerp(_object_base_scale * target, delta * SCALE_LERP)

# --- Interactable (driven by the local player's Hands) ----------------------

# Crosshair prompt fields, read by the HUD while this pedestal is targeted.
func interact_name() -> String:
	return "Match"

func interact_action() -> String:
	return "start"

# Only offer the pedestal between matches, while the lobby is waiting to start.
func can_interact() -> bool:
	return MatchManager.state == MatchManager.State.WAITING

# Clicked on the crosshair: open the lobby menu — a big START for the Classic tournament plus
# a Customise view (mode, map pick, player list). The match starts from there; the Start
# buttons stay disabled until the lobby has enough players.
func interact() -> void:
	if can_interact():
		MapSelect.open()

func set_targeted(value: bool) -> void:
	_targeted = value

# Where the crosshair should land to count as aiming at this pedestal: the floating object.
func interact_point() -> Vector3:
	if object and is_instance_valid(object):
		return object.global_position
	return global_position
