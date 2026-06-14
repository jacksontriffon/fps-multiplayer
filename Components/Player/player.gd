extends CharacterBody3D
class_name Player

# Networked first-person body. Movement runs only on the authority peer; the
# MultiplayerSynchronizer replicates position + body rotation (here) plus the look
# rotations (set by Head/head.gd). Look + camera live on the Head node.

const WALK_SPEED = 5.0
const SPRINT_SPEED = 7.0
const CROUCH_SPEED = 2.5
const JUMP_VELOCITY = 4.5

# Keep jumps reliable when sprinting flickers is_on_floor() off between floor
# seams: buffer a press briefly and allow a short post-ledge coyote window.
const JUMP_BUFFER := 0.12
const COYOTE_TIME := 0.1

# Friction
const AIR_FRICTION = 5.0
const GROUND_FRICTION = 10.0

# FOV
const BASE_FOV = 75.0
const FOV_CHANGE = 1.2

# Knockback (throw recoil + getting hit). Decays toward zero each frame and is
# layered on top of the input-driven velocity, which would otherwise clobber it.
const KNOCKBACK_DECAY = 8.0

# Dash (set by the Dash component). The per-frame impulse feeds into dash_vel, which
# builds up while you hold the dash and then bleeds off — the accumulation is what
# gives it punch. DASH_DECAY fades the feed; DASH_BLEED drains the built-up velocity.
# Both are applied in dash_vel regardless of floor state so a grounded dash builds up
# exactly like an air one (the base movement hard-set used to swallow it on the ground).
const DASH_DECAY = 4.0
const DASH_BLEED = 5.0

# Camera shake trauma added each time a ball hits us (see Head.add_trauma).
const HIT_TRAUMA = 0.6

# Knockdown stun: a fast hit ragdolls the body and suspends control for this long,
# then we stand back up. The first-person camera follows the tumble, but only leans
# part-way toward the body's fall (never a full invert) and eases there.
const KNOCKDOWN_TIME := 2.2
const KNOCKDOWN_CAM_LEAN := 0.35
const KNOCKDOWN_CAM_DAMP := 6.0

# Death cam: how long we frame the dead player's own body before swapping to spectate
# a living teammate.
const DEATH_CAM_TIME := 3.0

# Ragdoll proxy tuning. RAGDOLL_OFFSET is the mesh/collider centre in body space, so
# the proxy capsule lines up with the visible body. LIFT/TORQUE give the tumble life;
# RECOVER_LIFT un-sticks the body above the floor before it settles on stand-up.
const RAGDOLL_OFFSET := Vector3(0, 0.37879586, 0)
const RAGDOLL_LIFT := 2.0
const RAGDOLL_TORQUE := 8.0
const RECOVER_LIFT := 0.4

# Third-person spectator camera framing + orbit feel.
const SPEC_DISTANCE := 4.5
const SPEC_LOOK_HEIGHT := 1.0
const SPEC_PITCH_MIN := -0.2
const SPEC_PITCH_MAX := 1.2
const SPEC_STICK_SPEED := 2.5
const SPEC_MOUSE_SENS := 0.005

# Climbing (ropes/ladders). Click to grab the rope while in its Area3D; from there
# up/down climbs and jump leaps off.
const CLIMB_SNAP := 12.0
const CLIMB_DISMOUNT_PUSH := 3.0
# After leaping off, ignore the rope briefly so holding a direction into it doesn't
# instantly re-grab.
const CLIMB_REGRAB_LOCK := 0.35

# Stamina cost of sprinting (per second). The pool itself lives on the Stamina node.
const SPRINT_DRAIN := 22.0

const TEAM_COLORS := [Color.RED, Color.BLUE]

# Spectator phases for an eliminated player's local camera.
enum SpecPhase { DEATH_CAM, CHASE, FREE }

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var ragdoll: RigidBody3D = $Ragdoll
@onready var stamina: Stamina = $Stamina

@export var team: int = 0:
	set(value):
		team = value
		_apply_team_color()

# Which of the 3 inventory slots is selected (0..2). Set by the controlling peer
# via the number keys and replicated, so the server knows which held ball to equip.
@export var active_slot: int = 0

# Set by the Crouch component on the controlling peer and replicated, so every peer
# ducks the body. Read here to cap movement speed and suppress sprint while crouched.
@export var crouching: bool = false

var speed = WALK_SPEED
var _jump_buffer := 0.0
var _coyote := 0.0

# Set true on any frame this body jumps off the ground/coyote ledge. The
# DoubleJump child reads it so it never spends an air jump on the same press.
var jumped_from_ground := false
var knockback := Vector3.ZERO
var dash_impulse := Vector3.ZERO
var dash_vel := Vector3.ZERO
var _dash_last := Vector3.ZERO

var alive := true

# The Climbable (rope) we're currently inside, set by its Area3D on enter/exit. Only the
# authority peer acts on it; position then replicates the climb like any other movement.
var _climb_zone: Climbable = null
var _climbing := false
var _climb_regrab_lock := 0.0

# Knockdown / ragdoll state (authority-local). _knocked_down is the non-fatal stun;
# _ragdoll_active means the proxy is simulating and driving the body transform.
var _knocked_down := false
var _knockdown_timer := 0.0
var _ragdoll_active := false

# Spectator state (authority-local). spectate_text is read by the HUD.
var spectate_text := ""
var _spec_phase: int = SpecPhase.DEATH_CAM
var _death_cam_timer := 0.0
var _spec_target_id := 0
var _spec_yaw := 0.0
var _spec_pitch := 0.5
var _death_spot := Vector3.ZERO
var _spectator_cam: Camera3D

# Generic gameplay effects: effect id -> set of grantor sources. Tracking sources lets
# several grantors stack the same effect without clobbering each other, so the same
# effect can later move from the lobby zone onto a consumable item or ability. The HUD
# reads has_effect(INFINITE_HEARTS) to swap the heart row for a single heart + ∞.
const INFINITE_HEARTS := &"infinite_hearts"

# Movement abilities are off until an AbilityOrb grants them. The Dash/DoubleJump nodes
# gate on these, the Stamina node reserves each owned ability's cost as a container slice,
# and the HUD draws that container in the bar.
const ABILITY_DASH := &"ability_dash"
const ABILITY_DOUBLE_JUMP := &"ability_double_jump"

var _effects := {}

func has_effect(id: StringName) -> bool:
	return _effects.has(id)

func set_effect(id: StringName, active: bool, source: StringName = &"default") -> void:
	var sources: Dictionary = _effects.get(id, {})
	if active:
		sources[source] = true
		_effects[id] = sources
	else:
		sources.erase(source)
		if sources.is_empty():
			_effects.erase(id)

# True while the player can move, look, grab and throw — false when dead or stunned.
func controllable() -> bool:
	return alive and not _knocked_down

# Push this body around. Movement is simulated on this player's own authority peer,
# so knockback must be applied there: the local throw recoil calls this directly,
# while ball hits arrive from the server via apply_knockback_remote.
func apply_knockback(impulse: Vector3) -> void:
	knockback += impulse

# A dash burst from the Dash component. Set (not added) so re-dashing refreshes the
# lunge rather than stacking; integrated alongside knockback in _physics_process.
func apply_dash(impulse: Vector3) -> void:
	dash_impulse = impulse

# The server owns ball physics and detects hits, then calls this on the struck
# player's authority peer. Guarded so only the server (peer 1) can shove players.
@rpc("any_peer", "call_local", "reliable")
func apply_knockback_remote(impulse: Vector3) -> void:
	if not (multiplayer.get_remote_sender_id() in [0, 1]):
		return
	apply_knockback(impulse)
	# Impulse shoves us away from the ball, so the hit came from the opposite direction.
	if is_multiplayer_authority():
		HUD.hit_from(-impulse)
		head.add_trauma(HIT_TRAUMA)

# Server -> victim: a hard hit that ragdolls the body. duration is the no-control stun
# for a non-fatal knockdown; fatal=true means stay down and start the death sequence.
@rpc("any_peer", "call_local", "reliable")
func apply_knockdown(impulse: Vector3, duration: float, fatal: bool) -> void:
	if not (multiplayer.get_remote_sender_id() in [0, 1]):
		return
	if not is_multiplayer_authority():
		return
	HUD.hit_from(-impulse)
	head.add_trauma(HIT_TRAUMA)
	_begin_ragdoll(impulse)
	if fatal:
		_knocked_down = false
		_enter_spectate(true)
	else:
		_knocked_down = true
		_knockdown_timer = duration

func _enter_tree() -> void:
	set_multiplayer_authority(name.to_int())

func _ready() -> void:
	add_to_group("players")
	_apply_team_color()
	if is_multiplayer_authority():
		_request_spawn.rpc_id(1)

# Broadcast so every peer agrees on the alive flag. ragdolled=true (a death) keeps the
# body visible and solid so it can tumble and rest on the floor; ragdolled=false (a late
# join turned spectator) hides it like before.
@rpc("any_peer", "call_local", "reliable")
func set_alive_remote(value: bool, ragdolled: bool = false) -> void:
	if not (multiplayer.get_remote_sender_id() in [0, 1]):
		return
	alive = value
	if value:
		_revive()
		return
	velocity = Vector3.ZERO
	knockback = Vector3.ZERO
	dash_impulse = Vector3.ZERO
	dash_vel = Vector3.ZERO
	_dash_last = Vector3.ZERO
	if not ragdolled:
		mesh.visible = false
		collision_shape.disabled = true
		if is_multiplayer_authority():
			_enter_spectate(false)

@rpc("any_peer", "call_local", "reliable")
func respawn_remote(pos: Vector3, yaw: float, t: int) -> void:
	if not (multiplayer.get_remote_sender_id() in [0, 1]):
		return
	team = t
	velocity = Vector3.ZERO
	knockback = Vector3.ZERO
	dash_impulse = Vector3.ZERO
	dash_vel = Vector3.ZERO
	_dash_last = Vector3.ZERO
	stamina.refill()
	global_rotation = Vector3.ZERO
	position = pos
	head.rotation.y = yaw
	camera.rotation = Vector3.ZERO

func _apply_team_color() -> void:
	if not is_node_ready():
		return
	var mat := StandardMaterial3D.new()
	# team < 0 means teamless (in the lobby, before a match assigns sides) — show neutral grey.
	mat.albedo_color = Color(0.8, 0.8, 0.8) if team < 0 else TEAM_COLORS[team % TEAM_COLORS.size()]
	mesh.material_override = mat

# call_local so the host's own rpc_id(1) runs on the server too — a self-RPC is
# skipped without it, which would leave the host unregistered with MatchManager.
@rpc("any_peer", "call_local", "reliable")
func _request_spawn() -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id == 0:
		peer_id = 1
	var spawner := MatchManager.current_spawner()
	if spawner == null:
		return
	# Lobby join: any free spot, no team yet (teams are assigned when a match starts).
	var spawn: Dictionary = spawner.reserve_any(peer_id)
	_apply_spawn.rpc_id(peer_id, spawn["position"], spawn["yaw"], spawn["team"])
	MatchManager.server_player_ready(peer_id)

@rpc("any_peer", "call_local", "reliable")
func _apply_spawn(pos: Vector3, yaw: float, t: int) -> void:
	if not (multiplayer.get_remote_sender_id() in [0, 1]):
		return
	team = t
	velocity = Vector3.ZERO
	position = pos
	head.rotation.y = yaw

func _physics_process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	if not is_multiplayer_authority():
		return

	# While the pause overlay is up the player ignores control input but keeps
	# simulating (gravity, knockback, collisions) so the world stays live behind it.
	var input_blocked: bool = Global.is_input_blocked()

	if not alive:
		_process_spectate(delta, input_blocked)
		return

	if _knocked_down:
		_process_knockdown(delta)
		return

	if not input_blocked:
		_handle_slot_input()

	# Undo last frame's dash before the movement math so it can't feed back into the
	# inertia integrator (the air/standing lerps read velocity); it's re-added below.
	velocity -= _dash_last
	_dash_last = Vector3.ZERO

	# Climbing a rope overrides normal locomotion, gravity, and dash while it's active.
	if _update_climb(delta, input_blocked):
		dash_impulse = Vector3.ZERO
		dash_vel = Vector3.ZERO
		move_and_slide()
		return

	# Add the gravity.
	if not is_on_floor():
		velocity += get_gravity() * delta

	# Handle jump. Buffer the press and track a coyote window so a jump isn't
	# dropped on a frame where is_on_floor() flickers off mid-sprint. The
	# mid-air double jump lives in the DoubleJump child node.
	_coyote = COYOTE_TIME if is_on_floor() else maxf(_coyote - delta, 0.0)
	if not input_blocked and Input.is_action_just_pressed("jump"):
		_jump_buffer = JUMP_BUFFER
	else:
		_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	jumped_from_ground = _jump_buffer > 0.0 and _coyote > 0.0
	if jumped_from_ground:
		velocity.y = JUMP_VELOCITY
		_jump_buffer = 0.0
		_coyote = 0.0

	# Handle movement direction
	var input_dir := Vector2.ZERO if input_blocked else Input.get_vector("left", "right", "up", "down")
	var direction = (head.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	# Handle Sprint — burns stamina, and only while actually moving. Crouch caps speed
	# and locks out the sprint.
	if crouching:
		speed = CROUCH_SPEED
	elif not input_blocked and Input.is_action_pressed("sprint") and direction and stamina.has_stamina():
		speed = SPRINT_SPEED
		stamina.drain(SPRINT_DRAIN * delta)
	else:
		speed = WALK_SPEED
	if is_on_floor():
		if direction:
			velocity.x = direction.x * speed
			velocity.z = direction.z * speed
		else:
			# Handle ground inertia
			velocity.x = lerp(velocity.x, direction.x * speed, delta * GROUND_FRICTION)
			velocity.z = lerp(velocity.z, direction.z * speed, delta * GROUND_FRICTION)
	else:
		# Handle air inertia
		velocity.x = lerp(velocity.x, direction.x * speed, delta * AIR_FRICTION)
		velocity.z = lerp(velocity.z, direction.z * speed, delta * AIR_FRICTION)

	# Layer knockback on top of the input-driven velocity (the lines above
	# overwrite x/z outright, so knockback has to be added after them), then decay.
	velocity += knockback
	knockback = knockback.lerp(Vector3.ZERO, delta * KNOCKBACK_DECAY)
	# Feed the dash impulse into dash_vel so it builds up, then bleeds. Subtracting
	# _dash_last above kept this off the base inertia, so the buildup is the same on
	# the ground as in the air rather than runaway in one and dead in the other.
	dash_vel = dash_vel.lerp(Vector3.ZERO, delta * DASH_BLEED)
	dash_vel += dash_impulse
	_dash_last = dash_vel
	velocity += _dash_last
	dash_impulse = dash_impulse.lerp(Vector3.ZERO, delta * DASH_DECAY)

	# FOV
	var velocity_clamped = clamp(velocity.length(), 0.5, SPRINT_SPEED * 2)
	var target_fov = BASE_FOV + FOV_CHANGE * velocity_clamped
	camera.fov = lerp(camera.fov, target_fov, delta * 8.0)

	move_and_slide()

# Number keys 1/2/3 pick the active inventory slot, equipping that slot's held ball.
func _handle_slot_input() -> void:
	if Input.is_action_just_pressed("slot_1"):
		active_slot = 0
	elif Input.is_action_just_pressed("slot_2"):
		active_slot = 1
	elif Input.is_action_just_pressed("slot_3"):
		active_slot = 2

# --- Ragdoll ----------------------------------------------------------------

# Place the local-sim proxy at the body, unfreeze it and launch it. From here each
# physics frame mirrors the proxy's transform onto the networked CharacterBody.
func _begin_ragdoll(impulse: Vector3) -> void:
	_ragdoll_active = true
	collision_shape.disabled = true  # the proxy is the physical body while tumbling
	ragdoll.global_transform = Transform3D(global_transform.basis, global_transform * RAGDOLL_OFFSET)
	ragdoll.linear_velocity = Vector3.ZERO
	ragdoll.angular_velocity = Vector3.ZERO
	ragdoll.collision_layer = 1
	ragdoll.collision_mask = 1
	ragdoll.freeze = false
	ragdoll.sleeping = false
	ragdoll.apply_central_impulse(impulse + Vector3.UP * RAGDOLL_LIFT)
	var torque := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
	ragdoll.apply_torque_impulse(torque * RAGDOLL_TORQUE)
	velocity = Vector3.ZERO
	knockback = Vector3.ZERO

# Copy the tumbling proxy onto the CharacterBody (which is what replicates), keeping
# the visible mesh aligned with the proxy capsule.
func _mirror_ragdoll() -> void:
	var b := ragdoll.global_transform.basis.orthonormalized()
	global_transform = Transform3D(b, ragdoll.global_position - b * RAGDOLL_OFFSET)

func _process_knockdown(delta: float) -> void:
	_mirror_ragdoll()
	_tame_first_person_camera(delta)
	_knockdown_timer -= delta
	if _knockdown_timer <= 0.0:
		_recover()

# Stand back up: freeze the proxy, snap upright at its resting XZ with a small upward
# un-stick, then a move_and_slide settle so we can't recover inside geometry.
func _recover() -> void:
	_knocked_down = false
	_ragdoll_active = false
	var rest := ragdoll.global_position
	ragdoll.freeze = true
	ragdoll.linear_velocity = Vector3.ZERO
	ragdoll.angular_velocity = Vector3.ZERO
	ragdoll.collision_layer = 0
	ragdoll.collision_mask = 0
	global_rotation = Vector3.ZERO
	global_position = rest - RAGDOLL_OFFSET + Vector3.UP * RECOVER_LIFT
	camera.rotation = Vector3.ZERO
	collision_shape.disabled = false
	velocity = Vector3.ZERO
	knockback = Vector3.ZERO
	move_and_slide()

func is_climbing() -> bool:
	return _climbing

# Called by a Climbable's Area3D on enter/exit (runs on every peer; only the authority
# acts on it). Leaving the rope we're on drops us off it.
func set_climb_zone(zone: Climbable, inside: bool) -> void:
	if inside:
		_climb_zone = zone
	elif _climb_zone == zone:
		_climb_zone = null
		_climbing = false

# A rope is in reach and we're not already on one; Hands' click handler gates on this.
func can_grab_climb() -> bool:
	return _climb_zone != null and not _climbing and _climb_regrab_lock <= 0.0

# Latch onto the rope we're standing in. From here up/down climbs and jump leaps off.
func grab_climb() -> void:
	if can_grab_climb():
		_climbing = true

# Returns true while actively climbing, so _physics_process skips normal movement/gravity.
# Climbing only begins via grab_climb() (a click) — never automatically from movement input.
func _update_climb(delta: float, input_blocked: bool) -> bool:
	_climb_regrab_lock = maxf(_climb_regrab_lock - delta, 0.0)
	if not _climbing:
		return false
	# Dropped out of range, or a solid hit shook us loose.
	if _climb_zone == null or knockback.length() > 1.0:
		_climbing = false
		return false
	# Jump leaps off the rope, out the way you're facing.
	if not input_blocked and Input.is_action_just_pressed("jump"):
		_climbing = false
		_climb_regrab_lock = CLIMB_REGRAB_LOCK
		velocity = -head.global_transform.basis.z * CLIMB_DISMOUNT_PUSH
		velocity.y = JUMP_VELOCITY
		return true
	# Cling to the rope: ease onto its centre line and drive straight up or down.
	var climb_input := 0.0 if input_blocked else Input.get_axis("down", "up")
	var anchor := _climb_zone.global_position
	velocity.x = (anchor.x - global_position.x) * CLIMB_SNAP
	velocity.z = (anchor.z - global_position.z) * CLIMB_SNAP
	velocity.y = climb_input * _climb_zone.climb_speed
	knockback = Vector3.ZERO
	return true

# Restore an upright, controllable body and tear down any ragdoll / spectate. Runs on
# every peer via set_alive_remote(true) so remotes also see the body stand back up.
func _revive() -> void:
	_knocked_down = false
	_ragdoll_active = false
	_knockdown_timer = 0.0
	if is_instance_valid(ragdoll):
		ragdoll.freeze = true
		ragdoll.linear_velocity = Vector3.ZERO
		ragdoll.angular_velocity = Vector3.ZERO
		ragdoll.collision_layer = 0
		ragdoll.collision_mask = 0
	global_rotation = Vector3.ZERO
	mesh.visible = true
	collision_shape.disabled = false
	spectate_text = ""
	if is_multiplayer_authority():
		_exit_spectator_cam()

# Lean the first-person camera part-way into the fall and ease there, so it follows the
# body down without ever fully inverting.
func _tame_first_person_camera(delta: float) -> void:
	var fall := global_transform.basis
	var lean_up := Vector3.UP.slerp(fall.y.normalized(), KNOCKDOWN_CAM_LEAN)
	if lean_up.length() < 0.01:
		lean_up = Vector3.UP
	var fwd := -fall.z
	fwd = fwd - lean_up * fwd.dot(lean_up)
	if fwd.length() < 0.01:
		fwd = -camera.global_transform.basis.z
	var target := Basis.looking_at(fwd.normalized(), lean_up.normalized())
	var b := camera.global_transform.basis.slerp(target, clampf(delta * KNOCKDOWN_CAM_DAMP, 0.0, 1.0))
	camera.global_transform = Transform3D(b.orthonormalized(), camera.global_position)

# --- Spectator --------------------------------------------------------------

func _enter_spectate(show_own_body: bool) -> void:
	if not is_multiplayer_authority():
		return
	_ensure_spectator_cam()
	_death_spot = _body_center()
	_spec_yaw = head.rotation.y
	_spec_pitch = 0.5
	_spec_target_id = 0
	if show_own_body:
		_spec_phase = SpecPhase.DEATH_CAM
		_death_cam_timer = DEATH_CAM_TIME
	else:
		_cycle_target(1)

func _process_spectate(delta: float, input_blocked: bool) -> void:
	if _ragdoll_active:
		_mirror_ragdoll()
	if _spectator_cam == null or not is_instance_valid(_spectator_cam):
		_enter_spectate(false)
	if not input_blocked:
		var look := Input.get_vector("look_left", "look_right", "look_up", "look_down")
		_spec_yaw -= look.x * SPEC_STICK_SPEED * Global.joypad_sensitivity * delta
		_spec_pitch = clampf(_spec_pitch - look.y * SPEC_STICK_SPEED * Global.joypad_sensitivity * delta, SPEC_PITCH_MIN, SPEC_PITCH_MAX)
		# Reuse the attack / aim actions (throw / interaction) to cycle the spectated teammate.
		if _spec_phase != SpecPhase.DEATH_CAM:
			if Input.is_action_just_pressed("throw"):
				_cycle_target(1)
			elif Input.is_action_just_pressed("interaction"):
				_cycle_target(-1)
	match _spec_phase:
		SpecPhase.DEATH_CAM:
			_death_cam_timer -= delta
			spectate_text = "Spectating in %d" % maxi(0, int(ceil(_death_cam_timer)))
			_aim_camera_at(_body_center())
			if _death_cam_timer <= 0.0:
				_cycle_target(1)
		SpecPhase.CHASE:
			var tp := _target_player()
			if tp == null or MatchManager.lives.get(_spec_target_id, 0) <= 0:
				_cycle_target(1)
				tp = _target_player()
			if tp == null:
				spectate_text = "No teammates left"
				_aim_camera_at(_death_spot)
			else:
				spectate_text = "Spectating Player %d" % _spec_target_id
				_aim_camera_at(_body_center_of(tp))
		SpecPhase.FREE:
			spectate_text = "No teammates left"
			_aim_camera_at(_death_spot)

func _aim_camera_at(target: Vector3) -> void:
	if _spectator_cam == null or not is_instance_valid(_spectator_cam):
		return
	var look_at_point := target + Vector3(0, SPEC_LOOK_HEIGHT, 0)
	var dir := Vector3(cos(_spec_pitch) * sin(_spec_yaw), sin(_spec_pitch), cos(_spec_pitch) * cos(_spec_yaw))
	_spectator_cam.global_position = look_at_point + dir * SPEC_DISTANCE
	_spectator_cam.look_at(look_at_point, Vector3.UP)

# Step to the next/prev living teammate, or fall back to a free orbit if none remain.
func _cycle_target(dir: int) -> void:
	var ids := _living_teammates()
	if ids.is_empty():
		_spec_phase = SpecPhase.FREE
		_spec_target_id = 0
		return
	var idx := ids.find(_spec_target_id)
	if idx == -1:
		idx = 0
	else:
		idx = (idx + dir + ids.size()) % ids.size()
	_spec_target_id = ids[idx]
	_spec_phase = SpecPhase.CHASE

# Living players on our team (teamless modes share team -1, so everyone alive counts),
# excluding ourselves, sorted by peer id for stable cycling.
func _living_teammates() -> Array:
	var my_team := MatchManager.team_of(name.to_int())
	var out: Array = []
	for p in get_tree().get_nodes_in_group("players"):
		if p == self:
			continue
		var pid: int = p.name.to_int()
		if MatchManager.lives.get(pid, 0) <= 0:
			continue
		if MatchManager.team_of(pid) != my_team:
			continue
		out.append(pid)
	out.sort()
	return out

func _target_player() -> Player:
	if _spec_target_id == 0:
		return null
	return get_tree().current_scene.get_node_or_null(str(_spec_target_id)) as Player

func _body_center() -> Vector3:
	return global_transform * RAGDOLL_OFFSET

func _body_center_of(p: Player) -> Vector3:
	return p.global_transform * RAGDOLL_OFFSET

func _ensure_spectator_cam() -> void:
	if _spectator_cam != null and is_instance_valid(_spectator_cam):
		return
	_spectator_cam = Camera3D.new()
	_spectator_cam.top_level = true
	add_child(_spectator_cam)
	_spectator_cam.make_current()

func _exit_spectator_cam() -> void:
	if _spectator_cam != null and is_instance_valid(_spectator_cam):
		_spectator_cam.queue_free()
	_spectator_cam = null
	if is_instance_valid(camera):
		camera.make_current()

# Mouse-look orbit for the spectator camera (stick look is handled in _process_spectate).
func _unhandled_input(event: InputEvent) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	if not is_multiplayer_authority() or alive:
		return
	if Global.is_input_blocked():
		return
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		var s := SPEC_MOUSE_SENS * Global.mouse_sensitivity
		_spec_yaw -= event.relative.x * s
		_spec_pitch = clampf(_spec_pitch + event.relative.y * s, SPEC_PITCH_MIN, SPEC_PITCH_MAX)
