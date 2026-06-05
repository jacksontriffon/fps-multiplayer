extends Node3D
class_name Hands

# Detection + highlighting are local to the controlling (authority) peer. Grab/throw
# are requested by the controlling peer but decided and executed by the server, which
# owns the balls. The held ball follows this hand (Grabbable does the per-frame snap),
# and the server replicates the result to everyone.

@export var camera: Camera3D

# Chargeup throw. Press-and-hold while holding a ball winds up power; releasing
# throws. A quick click barely charges, so it throws light. Time to full charge:
const THROW_CHARGE_TIME := 0.9

# Throw recoil, scaled by charge. The values below are the full-charge maximum;
# RECOIL_MIN_SCALE keeps a light throw from being completely kickless. The camera
# kick is a purely local positional offset (camera position isn't replicated, so
# remotes never see it) that springs back; the shove is a small backward knockback
# predicted on the throwing player's own body.
const RECOIL_KICK := Vector3(0.0, 0.07, 0.26)  # local cam space: up + back (full charge)
const RECOIL_RECOVER := 14.0
const RECOIL_SHOVE := 1.1  # full-charge backward shove
const RECOIL_MIN_SCALE := 0.3

var grabbable_objects: Array[Grabbable] = []
var highlighted: Grabbable = null

var _cam_base_pos := Vector3.ZERO
var _recoil_offset := Vector3.ZERO

# Throw charge state (local to the controlling peer). _charging is true while the
# button is held over a held ball; _charge ramps 0..1 in _physics_process.
var _charging := false
var _charge := 0.0

@onready var right_hand_marker := $MeshInstance3D/RightHandMarker

func _ready() -> void:
	_cam_base_pos = camera.position

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	update_highlight()
	_handle_interaction_input()
	# Wind up the throw while held, streaming charge to the ball so peers can redden it.
	if _charging:
		_charge = minf(_charge + delta / THROW_CHARGE_TIME, 1.0)
		_push_charge(_charge)
	# Spring the camera back toward its resting position.
	_recoil_offset = _recoil_offset.lerp(Vector3.ZERO, delta * RECOIL_RECOVER)
	camera.position = _cam_base_pos + _recoil_offset

# Polled, not event-driven: an analog trigger (e.g. R2 on throw) streams motion
# events that all read as "pressed", which would reset the charge every frame.
# Input.is_action_just_* edge-detects correctly for both buttons and axes.
func _handle_interaction_input() -> void:
	# Grab happens immediately on press, and only with empty hands.
	if Input.is_action_just_pressed("interaction") and not _held_ball_of(get_multiplayer_authority()):
		_send_interact(0.0)
	# Throw: hold to wind up power, release to let go — only while holding a ball.
	if Input.is_action_just_pressed("throw") and _held_ball_of(get_multiplayer_authority()):
		_charging = true
		_charge = 0.0
	elif Input.is_action_just_released("throw") and _charging:
		_charging = false
		var aim := -camera.global_transform.basis.z
		var power := _charge
		_send_interact(power)
		_apply_throw_recoil(aim, power)

# Routes a grab/throw to the server: the host (peer 1) runs it directly; clients
# ask it to. power is the 0..1 throw charge (ignored by the server for grabs).
func _send_interact(power: float) -> void:
	var target_path: NodePath = highlighted.get_path() if highlighted else NodePath()
	var aim := -camera.global_transform.basis.z
	if multiplayer.is_server():
		_do_interact(get_multiplayer_authority(), target_path, aim, power)
	else:
		_request_interact.rpc_id(1, target_path, aim, power)

# Local-only feedback for the throwing player (not replicated). Recoil scales with
# the throw charge, with a floor so even a light throw kicks a little.
func _apply_throw_recoil(aim: Vector3, power: float) -> void:
	var scale := lerpf(RECOIL_MIN_SCALE, 1.0, clampf(power, 0.0, 1.0))
	_recoil_offset += RECOIL_KICK * scale
	var player := _get_player()
	if player:
		player.apply_knockback(-aim * RECOIL_SHOVE * scale)

func _get_player() -> Player:
	var node := get_parent()
	while node and not (node is Player):
		node = node.get_parent()
	return node

# Push charge to the held ball; host writes it, clients ask the server (it replicates).
func _push_charge(value: float) -> void:
	var held := _held_ball_of(get_multiplayer_authority())
	if held == null:
		return
	if multiplayer.is_server():
		held.charge = value
	else:
		held._set_charge.rpc_id(1, value)

# Read by the local HUD to drive the charge bar.
func is_charging() -> bool:
	return _charging

func get_charge() -> float:
	return _charge

# --- Server-authoritative grab/throw ---------------------------------------

@rpc("any_peer", "reliable")
func _request_interact(target_path: NodePath, aim: Vector3, power: float) -> void:
	if not multiplayer.is_server():
		return
	# Only the peer that owns this hand may drive it.
	if multiplayer.get_remote_sender_id() != get_multiplayer_authority():
		return
	_do_interact(get_multiplayer_authority(), target_path, aim, power)

# Server only. Holding a ball => throw it (at the given charge); otherwise grab
# the requested target.
func _do_interact(peer_id: int, target_path: NodePath, aim: Vector3, power: float) -> void:
	var held := _held_ball_of(peer_id)
	if held:
		held.throw(aim, power)
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
