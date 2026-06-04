extends RigidBody3D
class_name Grabbable

# Server-authoritative networked physics object. Peer 1 (the host) is the sole
# authority: it simulates physics, performs grabs/throws, and replicates position,
# rotation and held_by via the MultiplayerSynchronizer. Every other peer freezes its
# copy and just displays the synced transform.

# Throw force scales with charge: a quick click throws at THROW_FORCE_MIN, a
# fully held-and-released throw at THROW_FORCE_MAX. throw() takes a 0..1 power.
const THROW_FORCE_MIN = 10.0
const THROW_FORCE_MAX = 30.0

# Hit pushback. Detection runs on the server (the only peer with real ball
# velocities — clients freeze their copies), which then RPCs the shove to the
# struck player's own authority peer, where its movement is simulated. The shove
# scales with the ball's speed, so a charged throw hits harder than a lobbed one.
const HIT_SPEED = 6.0           # min ball speed to count as a hit
const HIT_SPEED_MAX = 24.0      # speed at which knockback maxes out
const HIT_KNOCKBACK_MIN = 4.0   # shove at the hit threshold
const HIT_KNOCKBACK_MAX = 14.0  # shove at (or above) HIT_SPEED_MAX
const HIT_COOLDOWN = 0.3        # min seconds between hits from the same ball

# Charge tint reddens the ball for observers; it rises with charge, falls fast on release.
const TINT_RISE = 5.0
const TINT_FALL = 7.0

## Peer id of the holder, or 0 when free. Replicated; only the authority writes it.
## The setter runs on every peer (including clients, when the synchronizer applies the
## replicated value), so a held ball stops colliding everywhere. Without this, a client
## keeps its copy solid — and since the ball is snapped to the holder's hand (inside the
## capsule), move_and_slide flings the holder sideways.
@export var held_by: int = 0:
	set(value):
		held_by = value
		_apply_held_collision()

## Charge 0..1 while held; server-authoritative, replicated so every peer can redden the ball.
@export var charge: float = 0.0

# Server-only hit bookkeeping (the server is the only peer that detects hits).
# thrower_id stays set until someone else throws the ball, so a ball can never
# hit whoever last threw it — only opponents' balls get you out.
var thrower_id := 0
var _hit_cooldown := 0.0

# Local smoothed redness (0..1) driven from charge; visual only, not replicated.
var _tint := 0.0

func _ready() -> void:
	add_to_group("grabbable")
	_apply_held_collision()
	# Needed for get_colliding_bodies() in the server's hit check.
	contact_monitor = true
	max_contacts_reported = 8
	# Stop fast throws from tunnelling through the thin player capsule.
	continuous_cd = true

func _physics_process(delta: float) -> void:
	_update_charge_tint(delta)
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

# power is the 0..1 charge from the thrower (0 = quick click, 1 = full charge).
func throw(direction: Vector3, power: float = 1.0) -> void:
	# held_by still names the holder here — remember them before release() clears it,
	# so this ball can never knock back its own thrower.
	thrower_id = held_by
	_hit_cooldown = 0.0
	release()
	var force := lerpf(THROW_FORCE_MIN, THROW_FORCE_MAX, clampf(power, 0.0, 1.0))
	apply_central_impulse(direction * force)

func release() -> void:
	held_by = 0  # setter re-enables collision on every peer
	charge = 0.0  # stop reddening; observers fade their tint out
	freeze = false

# Streamed by the holding client each frame while charging. Server-authoritative.
@rpc("any_peer", "unreliable_ordered")
func _set_charge(value: float) -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != held_by:
		return
	charge = clampf(value, 0.0, 1.0)

# --- Server-side hit detection ---------------------------------------------

func _server_check_hit(delta: float) -> void:
	if _hit_cooldown > 0.0:
		_hit_cooldown -= delta
		return
	var speed := linear_velocity.length()
	if speed < HIT_SPEED:
		return
	# Faster balls shove harder. Captured here, before the contact loop, since a
	# bounce can change the velocity by the time we react to the collision.
	var speed_t := clampf((speed - HIT_SPEED) / (HIT_SPEED_MAX - HIT_SPEED), 0.0, 1.0)
	var knockback := lerpf(HIT_KNOCKBACK_MIN, HIT_KNOCKBACK_MAX, speed_t)
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
		var impulse := away.normalized() * knockback
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

# Ease displayed redness toward charge; the local holder sees no tint (they get the bar).
func _update_charge_tint(delta: float) -> void:
	var mine := held_by != 0 and held_by == multiplayer.get_unique_id()
	var target := 0.0 if mine else charge
	var speed := TINT_RISE if target > _tint else TINT_FALL
	_tint = move_toward(_tint, target, speed * delta)
	set_charge_visual(_tint)

# Overridden by subclasses that have a highlight visual.
func toggle_highlight(_is_highlighted: bool) -> void:
	pass

# Overridden by subclasses to tint the ball by charge (0..1).
func set_charge_visual(_tint_amount: float) -> void:
	pass
