extends CharacterBody3D

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

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D

var speed = WALK_SPEED

func _enter_tree() -> void:
	set_multiplayer_authority(name.to_int())

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
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

	# FOV
	var velocity_clamped = clamp(velocity.length(), 0.5, SPRINT_SPEED * 2)
	var target_fov = BASE_FOV + FOV_CHANGE * velocity_clamped
	camera.fov = lerp(camera.fov, target_fov, delta * 8.0)

	move_and_slide()
