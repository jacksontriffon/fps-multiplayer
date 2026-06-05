extends Node3D
class_name Pedestal

# Lobby start pedestal: step into range and interact to start the match. Like a
# grabbable, the orb highlights and a 3D prompt fades in while you're near; the
# prompt text says whether a match can start yet.

# Orb highlight: faint when idle, solid when the local player is in range.
const IDLE_ALPHA := 0.15
const HIGHLIGHT_ALPHA := 1.0
const ALPHA_LERP := 12.0

# Quick fade for the billboard prompt as you enter/leave range.
const PROMPT_LERP := 16.0

# Gentle idle bob of the orb (local visual; eased by the sine itself).
const BOB_AMPLITUDE := 0.09
const BOB_SPEED := 1.6

@onready var orb: CSGSphere3D = $CSGCylinder3D/CSGSphere3D
@onready var prompt: Label3D = $Prompt
@onready var area: Area3D = $Area3D

var _mat: StandardMaterial3D
var _orb_base_y := 0.0
var _bob_time := 0.0

func _ready() -> void:
	add_to_group("pedestal")
	_orb_base_y = orb.position.y
	_mat = StandardMaterial3D.new()
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.albedo_color = Color(0.6, 0.85, 1.0, IDLE_ALPHA)
	orb.material = _mat
	prompt.modulate.a = 0.0
	prompt.outline_modulate.a = 0.0

func _process(delta: float) -> void:
	_bob_time += delta
	orb.position.y = _orb_base_y + sin(_bob_time * BOB_SPEED) * BOB_AMPLITUDE

	var near := _local_near()
	# Orb brightens when you're in range, like a grabbable's outline.
	var target: float = HIGHLIGHT_ALPHA if near else IDLE_ALPHA
	_mat.albedo_color.a = lerpf(_mat.albedo_color.a, target, delta * ALPHA_LERP)

	# Quick fade for the prompt; keep the last text on screen while it fades out.
	var text := prompt_text()
	if text != "":
		prompt.text = text
	# Fade fill and outline together — Label3D renders the outline separately.
	var a := lerpf(prompt.modulate.a, 1.0 if text != "" else 0.0, delta * PROMPT_LERP)
	prompt.modulate.a = a
	prompt.outline_modulate.a = a

	if near and MatchManager.can_start() and Input.is_action_just_pressed("interaction"):
		_start()

# Empty when the prompt shouldn't show; the billboard Label3D renders whatever this returns.
func prompt_text() -> String:
	if MatchManager.state != MatchManager.State.WAITING or not _local_near():
		return ""
	if MatchManager.can_start():
		return "Interact to Start the Game"
	return "Add more players to start the game"

func _local_near() -> bool:
	var p := _local_player()
	return p != null and p in area.get_overlapping_bodies()

func _local_player() -> Node3D:
	if not multiplayer.has_multiplayer_peer():
		return null
	return get_tree().current_scene.get_node_or_null(str(multiplayer.get_unique_id()))

func _start() -> void:
	if multiplayer.is_server():
		MatchManager.server_request_start()
	else:
		MatchManager.request_start.rpc_id(1)
