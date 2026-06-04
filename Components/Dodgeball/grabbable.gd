extends RigidBody3D
class_name Grabbable

# Server-authoritative networked physics object. Peer 1 (the host) is the sole
# authority: it simulates physics, performs grabs/throws, and replicates position,
# rotation and held_by via the MultiplayerSynchronizer. Every other peer freezes its
# copy and just displays the synced transform.

const THROW_FORCE = 15.0

## Peer id of the holder, or 0 when free. Replicated; only the authority writes it.
## The setter runs on every peer (including clients, when the synchronizer applies the
## replicated value), so a held ball stops colliding everywhere. Without this, a client
## keeps its copy solid — and since the ball is snapped to the holder's hand (inside the
## capsule), move_and_slide flings the holder sideways.
@export var held_by: int = 0:
	set(value):
		held_by = value
		_apply_held_collision()

func _ready() -> void:
	add_to_group("grabbable")
	_apply_held_collision()

func _physics_process(_delta: float) -> void:
	if not is_multiplayer_authority():
		# Clients don't simulate — freeze and let the synchronizer drive the transform.
		# Done here (not _ready) so it also applies after a peer connects.
		if not freeze:
			freeze = true
		return

	if held_by == 0:
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
	release()
	apply_central_impulse(direction * THROW_FORCE)

func release() -> void:
	held_by = 0  # setter re-enables collision on every peer
	freeze = false

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
