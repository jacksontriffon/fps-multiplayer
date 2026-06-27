@tool
extends Node3D
class_name BallSpawner

# Drop into any map. While the spawn space stays clear, the server counts up to `interval` and
# then spawns a dodgeball; the MultiplayerSpawner child replicates it to every peer. A ghost
# ball and a radial bar, driven by the replicated `progress`/`pending`, show the countdown on
# every peer. Server-authoritative: only peer 1 runs the timer and spawns.

const BALL_SCENE := preload("res://Components/Dodgeball/dodgeball.tscn")

## Seconds the spawn space must stay clear before a fresh ball appears.
@export var interval: float = 60.0
## A spawn is held off while a ball or player sits within this radius of the spawn point.
@export var clear_radius: float = 1.0

## 0..1 fill of the radial bar; server-driven, replicated. Only meaningful while `pending`.
@export var progress: float = 0.0
## True while the space is clear and a ball is counting down to spawn here. Replicated.
@export var pending: bool = false

@onready var balls: Node3D = $Balls
@onready var ghost_ball: MeshInstance3D = $GhostBall
@onready var radial_bar: MeshInstance3D = $RadialBar

var _elapsed := 0.0

func _ready() -> void:
	if Engine.is_editor_hint():
		_show_editor_preview()
		return
	# Found by Hands so the triple-throw buff can borrow this spawner's replicated container.
	add_to_group("ball_spawner")

# Draw a translucent dodgeball at the spawn point so the spawner is visible while editing maps.
# Editor-only and owner-less, so it never serializes into the scene or ships to a running game.
func _show_editor_preview() -> void:
	if has_node("EditorPreview"):
		return
	var mesh := SphereMesh.new()
	mesh.radius = 0.25  # matches the dodgeball's visible BallMesh (default sphere scaled by 0.5)
	mesh.height = 0.5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.514, 0.902, 0.227)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = mat
	var preview := MeshInstance3D.new()
	preview.name = "EditorPreview"
	preview.mesh = mesh
	add_child(preview)

func _physics_process(delta: float) -> void:
	# Only the host runs the timer; mirrors grabbable.gd's guard so a peer connecting after
	# _ready still works. Clients just render the replicated progress in _process.
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	if not _space_clear():
		# Occupied: pause the countdown where it is, don't reset. It resumes once clear.
		return
	pending = true
	_elapsed += delta
	progress = clampf(_elapsed / interval, 0.0, 1.0)
	if _elapsed >= interval:
		_elapsed = 0.0
		progress = 0.0
		pending = false
		_spawn_ball()

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	ghost_ball.visible = pending
	radial_bar.visible = pending
	if pending:
		radial_bar.set_instance_shader_parameter(&"progress", progress)

# Restock an infinite-ammo holder's hand right after they throw, so they never run dry.
# Driven by the throw (see Hands), not polled, so the buff only ever replaces a ball that was
# in hand — it never conjures one into an empty hand on pickup. The grab() arms the fresh ball
# for ABILITY_BOMB carriers, so the refill carries whatever upgrades the holder has.
func refill_hand(player: Player) -> void:
	var ball := BALL_SCENE.instantiate()
	ball.ephemeral = true
	# force_readable_name so the node gets a non-reserved name; the MultiplayerSpawner
	# refuses to auto-replicate children whose auto-name starts with "@".
	balls.add_child(ball, true)  # under the MultiplayerSpawner's path, so it replicates to every peer
	if not ball.grab(player.name.to_int()):
		ball.queue_free()
		return
	var marker := player.get_node_or_null("Head/Camera3D/Hands/MeshInstance3D/RightHandMarker")
	if marker:
		ball.global_position = marker.global_position

# Conjure one extra ball already leaving a player's hand for the triple-throw buff, then
# throw it. Server-only; mirrors refill_hand but launches the ball instead of leaving it
# held. Ephemeral so the spread doesn't litter the arena. `as_bomb` matches the ball that was
# in hand: grab() already arms it for upgrade carriers, but an armed pickup held without the
# upgrade still needs arming so the spread is three bombs, not one bomb and two plain balls.
func launch_from_hand(player: Player, direction: Vector3, power: float, as_bomb: bool = false) -> void:
	var ball := BALL_SCENE.instantiate()
	ball.ephemeral = true
	balls.add_child(ball, true)  # under the MultiplayerSpawner's path, so it replicates to every peer
	if not ball.grab(player.name.to_int()):
		ball.queue_free()
		return
	if as_bomb:
		ball.arm_as_bomb()
	var marker := player.get_node_or_null("Head/Camera3D/Hands/MeshInstance3D/RightHandMarker")
	if marker:
		ball.global_position = marker.global_position
	ball.throw(direction, power)

# Don't pile a new ball onto an existing ball or a standing player.
func _space_clear() -> bool:
	var origin := balls.global_position
	for ball in get_tree().get_nodes_in_group("grabbable"):
		if (ball.global_position - origin).length() < clear_radius:
			return false
	for p in get_tree().get_nodes_in_group("players"):
		if (p.global_position - origin).length() < clear_radius:
			return false
	return true

func _spawn_ball() -> void:
	var ball := BALL_SCENE.instantiate()
	# Local zero = the spawn point; set before add_child so the spawn replication carries it.
	ball.position = Vector3.ZERO
	balls.add_child(ball, true)
