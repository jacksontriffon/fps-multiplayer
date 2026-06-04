extends Node3D
class_name Hands

# Detection + highlighting are local to the controlling (authority) peer. Grab/throw
# are requested by the controlling peer but decided and executed by the server, which
# owns the balls. The held ball follows this hand (Grabbable does the per-frame snap),
# and the server replicates the result to everyone.

@export var camera: Camera3D

var grabbable_objects: Array[Grabbable] = []
var highlighted: Grabbable = null

@onready var right_hand_marker := $MeshInstance3D/RightHandMarker

func _physics_process(_delta: float) -> void:
	if not is_multiplayer_authority():
		return
	update_highlight()

func _input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if event.is_action_pressed("interaction"):
		var target_path: NodePath = highlighted.get_path() if highlighted else NodePath()
		var aim := -camera.global_transform.basis.z
		# Decide on the server. The host (peer 1) runs it directly; clients ask it to.
		if multiplayer.is_server():
			_do_interact(get_multiplayer_authority(), target_path, aim)
		else:
			_request_interact.rpc_id(1, target_path, aim)

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
