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

# When stamina runs out mid-wind-up the charge bleeds back down over this time.
const THROW_DISCHARGE_TIME := 4.0

# A release below this charge counts as a quick tap, not a throw: it fires an available
# interaction (e.g. grabbing a rope) instead, so a ball only leaves your hand once wound up.
const THROW_MIN_CHARGE := 0.2

# Stamina cost of winding up a throw (per second).
const CHARGE_DRAIN := 25.0

# Throw recoil, scaled by charge. The values below are the full-charge maximum;
# RECOIL_MIN_SCALE keeps a light throw from being completely kickless. The camera
# kick is a purely local positional offset (camera position isn't replicated, so
# remotes never see it) that springs back; the shove is a small backward knockback
# predicted on the throwing player's own body.
const RECOIL_KICK := Vector3(0.0, 0.07, 0.26)  # local cam space: up + back (full charge)
const RECOIL_RECOVER := 14.0
const RECOIL_SHOVE := 1.1  # full-charge backward shove
const RECOIL_MIN_SCALE := 0.3

# Crosshair aiming. The ray probes up to AIM_MAX_DISTANCE for a target; on a miss
# (e.g. aiming at sky) the throw converges on a point AIM_DISTANCE down the sight line.
const AIM_DISTANCE := 50.0
const AIM_MAX_DISTANCE := 1000.0

# Grab targeting: a ball is only grabbable inside a narrow cone down the camera's
# center sight line. The Area3D in the scene is just the broad phase; this is the
# real filter.
const INTERACT_CONE_HALF_ANGLE := deg_to_rad(12.0)
const INTERACT_REACH := 3.0

var grabbable_objects: Array[Grabbable] = []
var highlighted: Grabbable = null

# World interactables (e.g. the lobby pedestal) overlapping the interaction area, plus the
# one currently on the crosshair. Same broad-phase + cone targeting as grabbable balls, but
# these stay in the world and run their own interact() instead of being picked up.
var interactables: Array[Node3D] = []
var highlighted_interactable: Node3D = null

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
	if not multiplayer.has_multiplayer_peer():
		return
	if not is_multiplayer_authority():
		return
	update_highlight()
	update_interactable_highlight()
	_update_interact_prompt()
	# No grabbing or throwing while the pause overlay is up.
	if not Global.is_input_blocked():
		_handle_interaction_input()
	# Wind up the throw while held, streaming charge to the ball so peers can redden it.
	# Charging burns stamina; once it's empty the wind-up bleeds back down to zero.
	if _charging:
		var player := _get_player()
		# Drop the wind-up if we died or lost the ball (e.g. a round reset), so it
		# stops draining stamina with nothing in hand.
		if player == null or not player.controllable() or _equipped_ball_of(player) == null:
			_charging = false
			_charge = 0.0
		else:
			if player.stamina.has_stamina():
				_charge = minf(_charge + delta / THROW_CHARGE_TIME, 1.0)
				player.stamina.drain(CHARGE_DRAIN * delta)
			else:
				_charge = maxf(_charge - delta / THROW_DISCHARGE_TIME, 0.0)
			_push_charge(_charge)
	# Spring the camera back toward its resting position.
	_recoil_offset = _recoil_offset.lerp(Vector3.ZERO, delta * RECOIL_RECOVER)
	camera.position = _cam_base_pos + _recoil_offset

# Polled, not event-driven: an analog trigger (e.g. R2 on throw) streams motion
# events that all read as "pressed", which would reset the charge every frame.
# Input.is_action_just_* edge-detects correctly for both buttons and axes.
func _handle_interaction_input() -> void:
	var me := _get_player()
	if me == null or not me.controllable():
		return
	# Empty hand: a click is a straight interaction (grab a ball you're aiming at, or
	# grab the rope you're standing in) — there's nothing to charge.
	if _equipped_ball_of(me) == null:
		if Input.is_action_just_pressed("interaction"):
			_try_interact(me)
		return
	# Holding a ball: hold to wind up a throw. A quick tap won't throw — it fires an
	# available interaction instead (e.g. grabbing the rope), so a ball is never lobbed
	# by accident and the rope stays clickable with a ball in hand.
	if Input.is_action_just_pressed("throw"):
		_charging = true
		_charge = 0.0
	elif Input.is_action_just_released("throw") and _charging:
		_charging = false
		if _charge >= THROW_MIN_CHARGE:
			var aim := _aim_dir()
			_send_interact(_charge)
			_apply_throw_recoil(aim, _charge)
		else:
			_try_interact(me)
		_charge = 0.0

# Drive the HUD's crosshair prompt to whatever a click would act on right now, mirroring
# _try_interact's priority: a free ball, then the rope, then a world interactable.
func _update_interact_prompt() -> void:
	var me := _get_player()
	if me == null or not me.controllable() or Global.is_input_blocked():
		HUD.hide_interact_prompt()
		return
	var target: Object = null
	if _equipped_ball_of(me) == null and highlighted != null:
		target = highlighted
	elif me.can_grab_climb():
		target = me.current_climb_zone()
	elif highlighted_interactable != null and is_instance_valid(highlighted_interactable):
		target = highlighted_interactable
	if target == null:
		HUD.hide_interact_prompt()
		return
	var obj_name: String = target.interact_name() if target.has_method("interact_name") else "Object"
	var verb: String = target.interact_action() if target.has_method("interact_action") else "use"
	HUD.show_interact_prompt(obj_name, &"interaction", verb)

# Fire the highest-priority instant interaction in reach. Returns true if one ran.
func _try_interact(me: Player) -> bool:
	# Grab a free ball only when our hand is empty and one is on the crosshair.
	if _equipped_ball_of(me) == null and highlighted != null:
		_send_interact(0.0)
		return true
	# Climbing a rope works whether or not we're holding a ball.
	if me.can_grab_climb():
		me.grab_climb()
		return true
	# Click a world interactable on the crosshair (e.g. the lobby pedestal), ball or no ball.
	if highlighted_interactable != null and is_instance_valid(highlighted_interactable):
		highlighted_interactable.interact()
		return true
	return false

# Routes a grab/throw to the server: the host (peer 1) runs it directly; clients
# ask it to. power is the 0..1 throw charge (ignored by the server for grabs).
func _send_interact(power: float) -> void:
	var target_path: NodePath = highlighted.get_path() if highlighted else NodePath()
	var aim := _aim_dir()
	if multiplayer.is_server():
		_do_interact(get_multiplayer_authority(), target_path, aim, power)
	else:
		_request_interact.rpc_id(1, target_path, aim, power)

# Throw direction: raycast down the crosshair to find what it actually points at,
# then aim the hand at that point. The hand sits ~0.5m right of the camera axis, so
# aiming parallel to the sight line (or at a fixed far distance) leaves the throw
# offset right at close range — converging on the real target point fixes it at any
# distance. Falls back to a far point on the sight line when the ray hits nothing.
func _aim_dir() -> Vector3:
	var origin := camera.global_position
	var forward := -camera.global_transform.basis.z
	var target := origin + forward * AIM_DISTANCE
	var query := PhysicsRayQueryParameters3D.create(origin, origin + forward * AIM_MAX_DISTANCE)
	var player := _get_player()
	if player:
		query.exclude = [player.get_rid()]  # don't aim at our own body
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit:
		target = hit.position
	return (target - right_hand_marker.global_position).normalized()

# Local-only feedback for the throwing player (not replicated). Recoil scales with
# the throw charge, with a floor so even a light throw kicks a little.
func _apply_throw_recoil(aim: Vector3, power: float) -> void:
	var scale := lerpf(RECOIL_MIN_SCALE, 1.0, clampf(power, 0.0, 1.0))
	_recoil_offset += RECOIL_KICK * scale
	var player := _get_player()
	# Skip the backward shove while climbing so a throw can't knock you off the rope.
	if player and not player.is_climbing():
		player.apply_knockback(-aim * RECOIL_SHOVE * scale)

func _get_player() -> Player:
	var node := get_parent()
	while node and not (node is Player):
		node = node.get_parent()
	return node

# Push charge to the held ball; host writes it, clients ask the server (it replicates).
func _push_charge(value: float) -> void:
	var held := _equipped_ball_of(_get_player())
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
	var actor := get_tree().current_scene.get_node_or_null(str(peer_id)) as Player
	if actor == null or not actor.alive:
		return
	# Holding a ball in the active slot => throw it; otherwise grab into that slot.
	var held := _equipped_ball_of(actor)
	if held:
		held.throw(aim, power)
		return
	if target_path.is_empty():
		return
	var ball := get_node_or_null(target_path) as Grabbable
	if ball:
		ball.grab(peer_id, actor.active_slot)

# --- Detection -------------------------------------------------------------
func _on_grabbable_area_body_entered(body: Node3D) -> void:
	if body is Grabbable:
		grabbable_objects.push_back(body)

func _on_grabbable_area_body_exited(body: Node3D) -> void:
	if body is Grabbable:
		grabbable_objects.erase(body)

# Interactables expose their collider as an Area3D; track the owning interactable node.
func _on_grabbable_area_area_entered(area: Area3D) -> void:
	var node := _interactable_of(area)
	if node and node not in interactables:
		interactables.push_back(node)

func _on_grabbable_area_area_exited(area: Area3D) -> void:
	var node := _interactable_of(area)
	if node:
		interactables.erase(node)

# Resolve a detected collider to the interactable node driving it: the collider itself, its
# scene owner, or its parent — whichever is in the "interactable" group.
func _interactable_of(area: Area3D) -> Node3D:
	for n in [area, area.owner, area.get_parent()]:
		if n is Node3D and n.is_in_group("interactable"):
			return n
	return null

# --- Highlight (local visual for the controlling peer) ---------------------
func update_highlight() -> void:
	# Nothing to highlight while the active slot already holds a ball.
	var target: Grabbable = null
	if _equipped_ball_of(_get_player()) == null:
		target = get_targeted_grabbable()
	if target == highlighted:
		return
	if highlighted:
		highlighted.toggle_highlight(false)
	if target:
		target.toggle_highlight(true)
	highlighted = target

# Highlight the interactable on the crosshair (swells it). Skipped while a grabbable ball
# is already targeted so the two never fight over one click.
func update_interactable_highlight() -> void:
	var target: Node3D = null
	if highlighted == null:
		target = get_targeted_interactable()
	if target == highlighted_interactable:
		return
	if highlighted_interactable != null and is_instance_valid(highlighted_interactable):
		highlighted_interactable.set_targeted(false)
	if target:
		target.set_targeted(true)
	highlighted_interactable = target

# The interactable most centered on the crosshair: in the interaction area and inside the
# cone, preferring the smallest angle off the sight line. Distance is already bounded by the
# broad-phase area overlap, so only the aim angle is filtered here.
func get_targeted_interactable() -> Node3D:
	var origin := camera.global_position
	var forward := -camera.global_transform.basis.z
	var best: Node3D = null
	var best_angle := INTERACT_CONE_HALF_ANGLE
	for node in interactables:
		if not is_instance_valid(node):
			continue
		if node.has_method("can_interact") and not node.can_interact():
			continue
		var point: Vector3 = node.interact_point() if node.has_method("interact_point") else node.global_position
		var to_node := point - origin
		if is_zero_approx(to_node.length()):
			continue
		var angle := forward.angle_to(to_node)
		if angle <= best_angle:
			best_angle = angle
			best = node
	return best

# The free ball most centered on the crosshair: inside the interaction cone and
# within reach, preferring the smallest angle off the sight line over proximity.
func get_targeted_grabbable() -> Grabbable:
	var origin := camera.global_position
	var forward := -camera.global_transform.basis.z
	var best: Grabbable = null
	var best_angle := INTERACT_CONE_HALF_ANGLE
	for object in grabbable_objects:
		if object.held_by != 0:
			continue  # skip balls someone is already holding
		var to_object: Vector3 = object.global_position - origin
		var dist := to_object.length()
		if dist > INTERACT_REACH or is_zero_approx(dist):
			continue
		var angle := forward.angle_to(to_object)
		if angle <= best_angle:
			best_angle = angle
			best = object
	return best

# The ball occupying the player's currently active slot, or null if it's empty.
func _equipped_ball_of(player: Player) -> Grabbable:
	if player == null:
		return null
	return _ball_in_slot(player.name.to_int(), player.active_slot)

func _ball_in_slot(peer_id: int, slot: int) -> Grabbable:
	for b in get_tree().get_nodes_in_group("grabbable"):
		if b is Grabbable and b.held_by == peer_id and b.held_slot == slot:
			return b
	return null
