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

func _ready() -> void:
	# Found by Hands so the triple-throw buff can borrow this spawner's replicated container.
	add_to_group("ball_spawner")

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
