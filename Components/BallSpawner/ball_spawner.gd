extends Node3D
class_name BallSpawner

# Drop into any map. Every `interval` seconds the server checks the spawn space and, if no ball
# or player is sitting in it, spawns a fresh dodgeball there. The MultiplayerSpawner child
# replicates each new ball to every peer. Server-authoritative: only peer 1 spawns.

const BALL_SCENE := preload("res://Components/Dodgeball/dodgeball.tscn")

## Seconds between spawn attempts.
@export var interval: float = 60.0
## A spawn is skipped while a ball or player sits within this radius of the spawn point.
@export var clear_radius: float = 1.0

@onready var balls: Node3D = $Balls

var _elapsed := 0.0

func _physics_process(delta: float) -> void:
	# Only the host spawns; mirrors grabbable.gd's guard so a peer connecting after _ready works.
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	_elapsed += delta
	if _elapsed < interval:
		return
	_elapsed = 0.0
	if _space_clear():
		_spawn_ball()

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
	balls.add_child(ball)
