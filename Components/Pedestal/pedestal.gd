extends Node3D
class_name Pedestal

# Lobby start-game pedestal. Any player who walks up and interacts starts the match;
# the orb glows when a match can start and dims to a disabled state otherwise. The
# HUD reads prompt_text() to show the contextual message.

const INTERACT_RANGE := 3.5
const ENABLED_ALPHA := 1.0
const DISABLED_ALPHA := 0.16
const ALPHA_LERP := 8.0

@onready var orb: CSGSphere3D = $CSGCylinder3D/CSGSphere3D

var _mat: StandardMaterial3D

func _ready() -> void:
	add_to_group("pedestal")
	_mat = StandardMaterial3D.new()
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.albedo_color = Color(0.35, 0.85, 1.0, DISABLED_ALPHA)
	_mat.emission_enabled = true
	_mat.emission = Color(0.25, 0.75, 1.0)
	orb.material = _mat

func _process(delta: float) -> void:
	var enabled := MatchManager.can_start()
	var target: float = ENABLED_ALPHA if enabled else DISABLED_ALPHA
	_mat.albedo_color.a = lerpf(_mat.albedo_color.a, target, delta * ALPHA_LERP)
	_mat.emission_energy_multiplier = lerpf(_mat.emission_energy_multiplier, 1.0 if enabled else 0.2, delta * ALPHA_LERP)
	if enabled and _local_near() and Input.is_action_just_pressed("interaction"):
		_start()

# Empty when the prompt shouldn't show; the HUD displays whatever this returns.
func prompt_text() -> String:
	if MatchManager.state != MatchManager.State.WAITING or not _local_near():
		return ""
	if MatchManager.can_start():
		return "Interact to Start the Game"
	return "Add more players to start the game"

func _local_near() -> bool:
	var p := _local_player()
	return p != null and p.global_position.distance_to(global_position) <= INTERACT_RANGE

func _local_player() -> Node3D:
	if not multiplayer.has_multiplayer_peer():
		return null
	return get_tree().current_scene.get_node_or_null(str(multiplayer.get_unique_id()))

func _start() -> void:
	if multiplayer.is_server():
		MatchManager.server_request_start()
	else:
		MatchManager.request_start.rpc_id(1)
