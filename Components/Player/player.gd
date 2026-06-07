extends CharacterBody3D
class_name Player

# Networked first-person body. Movement runs only on the authority peer; the
# MultiplayerSynchronizer replicates position (here) plus the look rotations
# (set by Head/head.gd). Look + camera live on the Head node.

const WALK_SPEED = 5.0
const SPRINT_SPEED = 7.0
const JUMP_VELOCITY = 4.5

# Friction
const AIR_FRICTION = 5.0
const GROUND_FRICTION = 10.0

# FOV
const BASE_FOV = 75.0
const FOV_CHANGE = 1.2

# Knockback (throw recoil + getting hit). Decays toward zero each frame and is
# layered on top of the input-driven velocity, which would otherwise clobber it.
const KNOCKBACK_DECAY = 8.0

# Camera shake trauma added each time a ball hits us (see Head.add_trauma).
const HIT_TRAUMA = 0.6

const FLY_SPEED = 10.0

const TEAM_COLORS := [Color.RED, Color.BLUE]

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D

@export var team: int = 0:
	set(value):
		team = value
		_apply_team_color()

var speed = WALK_SPEED
var knockback := Vector3.ZERO

var alive := true

# Push this body around. Movement is simulated on this player's own authority peer,
# so knockback must be applied there: the local throw recoil calls this directly,
# while ball hits arrive from the server via apply_knockback_remote.
func apply_knockback(impulse: Vector3) -> void:
	knockback += impulse

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

@rpc("any_peer", "call_local", "reliable")
func respawn_remote(pos: Vector3, yaw: float) -> void:
	if not (multiplayer.get_remote_sender_id() in [0, 1]):
		return
	velocity = Vector3.ZERO
	knockback = Vector3.ZERO
	position = pos
	head.rotation.y = yaw

func _apply_team_color() -> void:
	if not is_node_ready():
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = TEAM_COLORS[team % TEAM_COLORS.size()]
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
	var spawner := get_tree().get_first_node_in_group("spawn_points")
	if spawner == null:
		return
	var spawn: Dictionary = spawner.reserve(peer_id)
	_apply_spawn.rpc_id(peer_id, spawn["position"], spawn["yaw"], spawn["team"])
	MatchManager.server_player_ready(peer_id, spawn["team"])

@rpc("any_peer", "call_local", "reliable")
func _apply_spawn(pos: Vector3, yaw: float, t: int) -> void:
	if not (multiplayer.get_remote_sender_id() in [0, 1]):
		return
	team = t
	velocity = Vector3.ZERO
	position = pos
	head.rotation.y = yaw

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	if not alive:
		_spectate()
		return

	# Add the gravity.
	if not is_on_floor():
		velocity += get_gravity() * delta

	# Handle jump.
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# Handle Sprint
	if Input.is_action_pressed("sprint"):
		speed = SPRINT_SPEED
	else:
		speed = WALK_SPEED

	# Handle movement direction
	var input_dir := Input.get_vector("left", "right", "up", "down")
	var direction = (head.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
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

	# FOV
	var velocity_clamped = clamp(velocity.length(), 0.5, SPRINT_SPEED * 2)
	var target_fov = BASE_FOV + FOV_CHANGE * velocity_clamped
	camera.fov = lerp(camera.fov, target_fov, delta * 8.0)

	move_and_slide()

func _spectate() -> void:
	var input_dir := Input.get_vector("left", "right", "up", "down")
	var dir := camera.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)
	if Input.is_action_pressed("jump"):
		dir.y += 1.0
	if Input.is_action_pressed("sprint"):
		dir.y -= 1.0
	velocity = dir.normalized() * FLY_SPEED if dir.length() > 0.01 else Vector3.ZERO
	move_and_slide()
