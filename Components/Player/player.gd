extends CharacterBody3D
class_name Player

# Networked first-person body. Movement runs only on the authority peer; the
# MultiplayerSynchronizer replicates position (here) plus the look rotations
# (set by Head/head.gd). Look + camera live on the Head node.

const WALK_SPEED = 5.0
const SPRINT_SPEED = 7.0
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

# Dash impulse channel (set by the Dash component). Same idea as knockback, but a
# slower decay so a dash reads as a sustained lunge instead of a quick shove that
# the walk speed swallows. Kept separate so it doesn't change how hits feel.
const DASH_DECAY = 4.0

# Camera shake trauma added each time a ball hits us (see Head.add_trauma).
const HIT_TRAUMA = 0.6

const FLY_SPEED = 10.0

# Stamina. Sprinting and winding up a throw both burn it; it refills after a short
# idle. CHARGE_DRAIN is read by Hands while charging.
const MAX_STAMINA := 150.0
const SPRINT_DRAIN := 22.0
const CHARGE_DRAIN := 25.0
const STAMINA_REGEN := 20.0
const STAMINA_REGEN_DELAY := 0.6

const TEAM_COLORS := [Color.RED, Color.BLUE]

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D

@export var team: int = 0:
	set(value):
		team = value
		_apply_team_color()

# Which of the 3 inventory slots is selected (0..2). Set by the controlling peer
# via the number keys and replicated, so the server knows which held ball to equip.
@export var active_slot: int = 0

var speed = WALK_SPEED
var _jump_buffer := 0.0
var _coyote := 0.0
var knockback := Vector3.ZERO
var dash_impulse := Vector3.ZERO
var stamina := MAX_STAMINA
var _regen_delay := 0.0

var alive := true

# Generic gameplay effects: effect id -> set of grantor sources. Tracking sources lets
# several grantors stack the same effect without clobbering each other, so the same
# effect can later move from the lobby zone onto a consumable item or ability. The HUD
# reads has_effect(INFINITE_HEARTS) to swap the heart row for a single heart + ∞.
const INFINITE_HEARTS := &"infinite_hearts"

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

# Stamina is spent by sprinting (here) and by charging a throw (Hands calls these).
func has_stamina() -> bool:
	return stamina > 0.0

func drain_stamina(amount: float) -> void:
	stamina = maxf(stamina - amount, 0.0)
	_regen_delay = STAMINA_REGEN_DELAY

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
	if multiplayer.get_remote_sender_id() != 1:
		return
	apply_knockback(impulse)
	# Impulse shoves us away from the ball, so the hit came from the opposite direction.
	if is_multiplayer_authority():
		HUD.hit_from(-impulse)
		head.add_trauma(HIT_TRAUMA)

func _enter_tree() -> void:
	set_multiplayer_authority(name.to_int())

func _ready() -> void:
	add_to_group("players")
	_apply_team_color()
	if is_multiplayer_authority():
		_request_spawn.rpc_id(1)

# Broadcast so the body stops colliding on every peer, including the server's copy.
@rpc("any_peer", "call_local", "reliable")
func set_alive_remote(value: bool) -> void:
	if not (multiplayer.get_remote_sender_id() in [0, 1]):
		return
	alive = value
	mesh.visible = value
	collision_shape.disabled = not value
	if not value:
		velocity = Vector3.ZERO
		knockback = Vector3.ZERO
		dash_impulse = Vector3.ZERO

@rpc("any_peer", "call_local", "reliable")
func respawn_remote(pos: Vector3, yaw: float, t: int) -> void:
	if not (multiplayer.get_remote_sender_id() in [0, 1]):
		return
	team = t
	velocity = Vector3.ZERO
	knockback = Vector3.ZERO
	dash_impulse = Vector3.ZERO
	stamina = MAX_STAMINA
	position = pos
	head.rotation.y = yaw

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

	if not input_blocked:
		_handle_slot_input()

	if not alive:
		_spectate(input_blocked)
		return

	# Add the gravity.
	if not is_on_floor():
		velocity += get_gravity() * delta

	# Handle jump. Buffer the press and track a coyote window so a jump isn't
	# dropped on a frame where is_on_floor() flickers off mid-sprint.
	_coyote = COYOTE_TIME if is_on_floor() else maxf(_coyote - delta, 0.0)
	if not input_blocked and Input.is_action_just_pressed("jump"):
		_jump_buffer = JUMP_BUFFER
	else:
		_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	if _jump_buffer > 0.0 and _coyote > 0.0:
		velocity.y = JUMP_VELOCITY
		_jump_buffer = 0.0
		_coyote = 0.0

	# Handle movement direction
	var input_dir := Vector2.ZERO if input_blocked else Input.get_vector("left", "right", "up", "down")
	var direction = (head.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	# Handle Sprint — burns stamina, and only while actually moving.
	if not input_blocked and Input.is_action_pressed("sprint") and direction and has_stamina():
		speed = SPRINT_SPEED
		drain_stamina(SPRINT_DRAIN * delta)
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
	velocity += dash_impulse
	dash_impulse = dash_impulse.lerp(Vector3.ZERO, delta * DASH_DECAY)

	# FOV
	var velocity_clamped = clamp(velocity.length(), 0.5, SPRINT_SPEED * 2)
	var target_fov = BASE_FOV + FOV_CHANGE * velocity_clamped
	camera.fov = lerp(camera.fov, target_fov, delta * 8.0)

	# Refill stamina once we've stopped spending it for a moment.
	_regen_delay = maxf(_regen_delay - delta, 0.0)
	if _regen_delay == 0.0 and stamina < MAX_STAMINA:
		stamina = minf(stamina + STAMINA_REGEN * delta, MAX_STAMINA)

	move_and_slide()

# Number keys 1/2/3 pick the active inventory slot, equipping that slot's held ball.
func _handle_slot_input() -> void:
	if Input.is_action_just_pressed("slot_1"):
		active_slot = 0
	elif Input.is_action_just_pressed("slot_2"):
		active_slot = 1
	elif Input.is_action_just_pressed("slot_3"):
		active_slot = 2

func _spectate(input_blocked: bool) -> void:
	var input_dir := Vector2.ZERO if input_blocked else Input.get_vector("left", "right", "up", "down")
	var dir := camera.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)
	if not input_blocked:
		if Input.is_action_pressed("jump"):
			dir.y += 1.0
		if Input.is_action_pressed("sprint"):
			dir.y -= 1.0
	velocity = dir.normalized() * FLY_SPEED if dir.length() > 0.01 else Vector3.ZERO
	move_and_slide()
