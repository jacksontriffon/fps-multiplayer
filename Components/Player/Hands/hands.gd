extends Node3D
class_name Hands

# Detection + highlighting are local to the controlling (authority) peer. Grab/throw
# are requested by the controlling peer but decided and executed by the server, which
# owns the balls. The held ball follows this hand (Grabbable does the per-frame snap),
# and the server replicates the result to everyone.

@export var camera: Camera3D

# Throw recoil. The camera kick is a purely local positional offset (camera position
# isn't replicated, so remotes never see it) that springs back; the shove is a small
# backward knockback predicted on the throwing player's own body.
const RECOIL_KICK := Vector3(0.0, 0.05, 0.18)  # local cam space: up + back
const RECOIL_RECOVER := 14.0
const RECOIL_SHOVE := 2.0

var grabbable_objects: Array[Grabbable] = []
var highlighted: Grabbable = null

var _cam_base_pos := Vector3.ZERO
var _recoil_offset := Vector3.ZERO

@onready var right_hand_marker := $MeshInstance3D/RightHandMarker

func _ready() -> void:
	_cam_base_pos = camera.position

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	update_highlight()
	# Spring the camera back toward its resting position.
	_recoil_offset = _recoil_offset.lerp(Vector3.ZERO, delta * RECOIL_RECOVER)
	camera.position = _cam_base_pos + _recoil_offset

func _input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if event.is_action_pressed("interaction"):
		var target_path: NodePath = highlighted.get_path() if highlighted else NodePath()
		var aim := -camera.global_transform.basis.z
		# Holding a ball => this press is a throw; predict the recoil locally.
		var is_throw := _held_ball_of(get_multiplayer_authority()) != null
		# Decide on the server. The host (peer 1) runs it directly; clients ask it to.
		if multiplayer.is_server():
			_do_interact(get_multiplayer_authority(), target_path, aim)
		else:
			_request_interact.rpc_id(1, target_path, aim)
		if is_throw:
			_apply_throw_recoil(aim)

# Local-only feedback for the throwing player (not replicated).
func _apply_throw_recoil(aim: Vector3) -> void:
	_recoil_offset += RECOIL_KICK
	var player := _get_player()
	if player:
		player.apply_knockback(-aim * RECOIL_SHOVE)

func _get_player() -> Player:
	var node := get_parent()
	while node and not (node is Player):
		node = node.get_parent()
	return node

# --- Server-authoritative grab/throw ---------------------------------------

@rpc("any_peer", "reliable")
func _request_interact(target_path: NodePath, aim: Vector3) -> void:
	if not multiplayer.is_server():
		return
	# Only the peer that owns this hand may drive it.
	if multiplayer.get_remote_sender_id() != get_multiplayer_authority():
		return
	_do_interact(get_multiplayer_authority(), target_path, aim)

# Server only. Holding a ball => throw it; otherwise grab the requested target.
func _do_interact(peer_id: int, target_path: NodePath, aim: Vector3) -> void:
	var held := _held_ball_of(peer_id)
	if held:
		held.throw(aim)
		return
	if target_path.is_empty():
		return
	var ball := get_node_or_null(target_path) as Grabbable
	if ball:
		ball.grab(peer_id)

# --- Detection -------------------------------------------------------------
func _on_grabbable_area_body_entered(body: Node3D) -> void:
	if body is Grabbable:
		grabbable_objects.push_back(body)

func _on_grabbable_area_body_exited(body: Node3D) -> void:
	if body is Grabbable:
		grabbable_objects.erase(body)

func _on_grabbable_area_area_entered(_area: Area3D) -> void:
	pass

func _on_grabbable_area_area_exited(_area: Area3D) -> void:
	pass

# --- Highlight (local visual for the controlling peer) ---------------------
func update_highlight() -> void:
	# Nothing to highlight while we're already holding a ball.
	var nearest: Grabbable = null
	if not _held_ball_of(get_multiplayer_authority()):
		nearest = get_nearest_grabbable_object()
	if nearest == highlighted:
		return
	if highlighted:
		highlighted.toggle_highlight(false)
	if nearest:
		nearest.toggle_highlight(true)
	highlighted = nearest

func get_nearest_grabbable_object() -> Grabbable:
	var nearest: Grabbable = null
	var nearest_dist := INF
	for object in grabbable_objects:
		if object.held_by != 0:
			continue  # skip balls someone is already holding
		var d := object.global_position.distance_squared_to(global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = object
	return nearest

func _held_ball_of(peer_id: int) -> Grabbable:
	for b in get_tree().get_nodes_in_group("grabbable"):
		if b is Grabbable and b.held_by == peer_id:
			return b
	return null
