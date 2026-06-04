extends RigidBody3D
class_name Grabbable

# Server-authoritative networked physics object. Peer 1 (the host) is the sole
# authority: it simulates physics, performs grabs/throws, and replicates position,
# rotation and held_by via the MultiplayerSynchronizer. Every other peer freezes its
# copy and just displays the synced transform.

const THROW_FORCE = 15.0

# Hit pushback. Detection runs on the server (the only peer with real ball
# velocities — clients freeze their copies), which then RPCs the shove to the
# struck player's own authority peer, where its movement is simulated.
const HIT_SPEED = 6.0        # min ball speed to count as a hit
const HIT_KNOCKBACK = 6.0    # shove strength applied to the struck player
const HIT_COOLDOWN = 0.3     # min seconds between hits from the same ball

## Peer id of the holder, or 0 when free. Replicated; only the authority writes it.
## The setter runs on every peer (including clients, when the synchronizer applies the
## replicated value), so a held ball stops colliding everywhere. Without this, a client
## keeps its copy solid — and since the ball is snapped to the holder's hand (inside the
## capsule), move_and_slide flings the holder sideways.
@export var held_by: int = 0:
	set(value):
		held_by = value
		_apply_held_collision()

# Server-only hit bookkeeping (the server is the only peer that detects hits).
# thrower_id stays set until someone else throws the ball, so a ball can never
# hit whoever last threw it — only opponents' balls get you out.
var thrower_id := 0
var _hit_cooldown := 0.0

func _ready() -> void:
	add_to_group("grabbable")
	_apply_held_collision()
	# Needed for get_colliding_bodies() in the server's hit check.
	contact_monitor = true
	max_contacts_reported = 8
	# Stop fast throws from tunnelling through the thin player capsule.
	continuous_cd = true

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		# Clients don't simulate — freeze and let the synchronizer drive the transform.
		# Done here (not _ready) so it also applies after a peer connects.
		if not freeze:
			freeze = true
		return

	if held_by == 0:
		# Free ball: the server simulates it and checks whether it has struck a player.
		_server_check_hit(delta)
		return

	# While held, snap to the holder's hand each frame; the synchronizer replicates the
	# result to everyone. Position only — the hand marker carries a large baked scale.
	var marker := _hand_marker_of(held_by)
	if marker:
		global_position = marker.global_position
	else:
		# Holder disconnected — drop the ball where it is.
		release()

# --- Authority-only state changes ------------------------------------------

## Returns true if the grab succeeded (ball was free).
func grab(peer_id: int) -> bool:
	if held_by != 0:
		return false  # already held; first grab wins
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	held_by = peer_id  # setter disables collision on every peer
	return true

func throw(direction: Vector3) -> void:
	# held_by still names the holder here — remember them before release() clears it,
	# so this ball can never knock back its own thrower.
	thrower_id = held_by
	_hit_cooldown = 0.0
	release()
	apply_central_impulse(direction * THROW_FORCE)

func release() -> void:
	held_by = 0  # setter re-enables collision on every peer
	freeze = false

# --- Server-side hit detection ---------------------------------------------

func _server_check_hit(delta: float) -> void:
	if _hit_cooldown > 0.0:
		_hit_cooldown -= delta
		return
	if linear_velocity.length() < HIT_SPEED:
		return
	for body in get_colliding_bodies():
		var player := body as Player
		if player == null:
			continue
		var victim_id := player.name.to_int()
		# Only opponents' balls hit you — never the one you last threw.
		if victim_id == thrower_id:
			continue
		# Shove the player away from the ball. We can't use the ball's velocity:
		# get_colliding_bodies() reports the contact a frame late, by which point
		# the ball has already bounced and its velocity points the wrong way.
		var away := player.global_position - global_position
		away.y = 0.0
		if away.length() < 0.01:
			away = -linear_velocity  # degenerate fallback
		var impulse := away.normalized() * HIT_KNOCKBACK
		player.apply_knockback_remote.rpc_id(victim_id, impulse)
		_hit_cooldown = HIT_COOLDOWN
		return

# --- Helpers ---------------------------------------------------------------

# A carried ball collides with nothing; a free ball uses the default world layer/mask.
func _apply_held_collision() -> void:
	var carried := held_by != 0
	collision_layer = 0 if carried else 1
	collision_mask = 0 if carried else 1

func _hand_marker_of(peer_id: int) -> Node3D:
	var player := get_tree().current_scene.get_node_or_null(str(peer_id))
	if player == null:
		return null
	return player.get_node_or_null("Head/Camera3D/Hands/MeshInstance3D/RightHandMarker")

# Overridden by subclasses that have a highlight visual.
func toggle_highlight(_is_highlighted: bool) -> void:
	pass
