extends Dodgeball
class_name ExplodingDodgeball

# A dodgeball that detonates after a fuse and/or on impact. The server owns all
# explosion logic (fuse, blast, respawn); clients only play the synced FX.

## Seconds after the throw before the ball detonates on its own; <= 0 means impact-only.
@export_range(0.0, 10.0, 0.1) var fuse_time := 2.5
## Detonate on the first contact (world or player) once armed.
@export var explode_on_impact := true
## Seconds after the throw before impacts can detonate, so the ball clears the thrower.
@export_range(0.0, 1.0, 0.05) var arm_delay := 0.15
## Players inside this radius are caught in the blast.
@export_range(1.0, 30.0, 0.5) var explosion_radius := 6.0
## Knockback right at the blast centre.
@export var knockback_center := 22.0
## Knockback at the edge of the radius.
@export var knockback_edge := 4.0
## 1 = linear falloff with distance; higher keeps the punch near the centre.
@export_range(0.5, 4.0, 0.1) var falloff_power := 1.5
## Extra upward shove blended into the blast direction so victims pop airborne.
@export_range(0.0, 1.0, 0.05) var upward_boost := 0.4
## Whether blast victims lose a life (same eligibility rules as a direct hit).
@export var costs_a_life := true
## Seconds the ball stays gone after exploding before respawning; < 0 = never.
@export var respawn_delay := 4.0

const WAVE_DURATION := 0.6
const FLASH_DURATION := 0.35
const FLASH_ENERGY := 8.0
const FUSE_PULSE_HZ_MIN := 2.0
const FUSE_PULSE_HZ_MAX := 12.0
const FUSE_COLOR := Color(1.0, 0.25, 0.05)

@onready var _blast_particles: GPUParticles3D = %ExplosionParticles
@onready var _blast_wave: MeshInstance3D = %BlastWave
@onready var _flash: OmniLight3D = %Flash

# Server-only explosion state.
var _fuse_left := -1.0
var _impact_armed := false
var _armed_age := 0.0
var _armed_thrower := 0  # blast credit survives the ball slowing down
var _respawn_left := 0.0

# Every peer: dormancy and the fuse-pulse visual, driven by the arm/explode/respawn RPCs.
var _dormant := false
var _fx_fusing := false
var _fx_fuse_left := 0.0
var _fx_fuse_total := 1.0
var _fx_clock := 0.0

func _physics_process(delta: float) -> void:
	super(delta)
	if not multiplayer.has_multiplayer_peer():
		return
	_update_fuse_fx(delta)
	if is_multiplayer_authority():
		_server_update_explosion(delta)

# --- Authority-only ----------------------------------------------------------

func throw(direction: Vector3, power: float = 1.0) -> void:
	_armed_thrower = held_by
	super(direction, power)
	_armed_age = 0.0
	_impact_armed = explode_on_impact
	# A re-thrown lit ball keeps its original countdown (hot potato).
	if fuse_time > 0.0 and _fuse_left < 0.0:
		_fuse_left = fuse_time
		_fx_arm.rpc(fuse_time)

func grab(peer_id: int, slot: int) -> bool:
	var grabbed := super(peer_id, slot)
	if grabbed:
		_impact_armed = false  # caught — but a lit fuse keeps burning
	return grabbed

func server_reset() -> void:
	if not is_multiplayer_authority():
		return
	_fuse_left = -1.0
	_impact_armed = false
	_armed_age = 0.0
	_armed_thrower = 0
	_fx_respawn.rpc()
	super()

func _server_update_explosion(delta: float) -> void:
	if _dormant:
		if respawn_delay >= 0.0:
			_respawn_left -= delta
			if _respawn_left <= 0.0:
				_server_respawn()
		return
	if _fuse_left >= 0.0:
		_fuse_left -= delta
		if _fuse_left <= 0.0:
			_server_detonate()
			return
	if not _impact_armed:
		return
	_armed_age += delta
	if held_by != 0 or _armed_age < arm_delay:
		return
	# Like the live-ball rule: once a free ball slows below hit speed it's safe again.
	if linear_velocity.length() < HIT_SPEED:
		_impact_armed = false
		return
	if get_colliding_bodies().size() > 0:
		_server_detonate()

# Armed balls explode instead of shoving on contact; unarmed ones act like a normal ball.
func _server_check_hit(delta: float) -> void:
	if _fuse_left >= 0.0 or _impact_armed:
		return
	super(delta)

func _server_detonate() -> void:
	if _dormant:
		return
	_fuse_left = -1.0
	_impact_armed = false
	# A ball stowed in a non-active slot parks at a stale position; blast at the holder.
	var holder := _holder()
	var center := holder.global_position if holder else global_position
	if held_by != 0:
		release()
	thrower_id = 0
	live_team = -1
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_apply_blast(center)
	_armed_thrower = 0
	_respawn_left = respawn_delay
	_fx_explode.rpc(center)

func _apply_blast(center: Vector3) -> void:
	for node in get_tree().get_nodes_in_group("players"):
		var player := node as Player
		if player == null or not player.alive:
			continue
		var victim_id := player.name.to_int()
		if not MatchManager.can_hit(victim_id, _armed_thrower):
			continue
		var to_victim := player.global_position - center
		var dist := to_victim.length()
		if dist > explosion_radius:
			continue
		# Closer = harder shove, aimed away from the blast centre plus an upward pop.
		var falloff := pow(1.0 - dist / explosion_radius, falloff_power)
		var strength := lerpf(knockback_edge, knockback_center, falloff)
		var away := to_victim / dist if dist > 0.01 else Vector3.UP
		var impulse := (away + Vector3.UP * upward_boost).normalized() * strength
		player.apply_knockback_remote.rpc_id(victim_id, impulse)
		if costs_a_life:
			MatchManager.server_on_hit(victim_id, _armed_thrower)
	# Free balls near the blast get tossed too.
	for node in get_tree().get_nodes_in_group("grabbable"):
		var ball := node as Grabbable
		if ball == null or ball == self or ball.held_by != 0 or ball.freeze:
			continue
		var to_ball := ball.global_position - center
		var dist := to_ball.length()
		if dist > explosion_radius or dist < 0.01:
			continue
		var falloff := pow(1.0 - dist / explosion_radius, falloff_power)
		var strength := lerpf(knockback_edge, knockback_center, falloff)
		ball.apply_central_impulse((to_ball / dist + Vector3.UP * upward_boost).normalized() * strength)

func _server_respawn() -> void:
	global_transform = _spawn_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	freeze = false
	_fx_respawn.rpc()

# --- FX, runs on every peer --------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _fx_arm(duration: float) -> void:
	_fx_fusing = duration > 0.0
	_fx_fuse_total = maxf(duration, 0.001)
	_fx_fuse_left = duration
	_fx_clock = 0.0

@rpc("authority", "call_local", "reliable")
func _fx_explode(center: Vector3) -> void:
	_fx_fusing = false
	_dormant = true
	_apply_held_collision()
	for fx: Node3D in [_blast_particles, _blast_wave, _flash]:
		fx.global_position = center
	_blast_particles.restart()
	_flash.omni_range = explosion_radius * 1.5
	_flash.light_energy = FLASH_ENERGY
	create_tween().tween_property(_flash, "light_energy", 0.0, FLASH_DURATION)
	_blast_wave.visible = true
	_blast_wave.set_instance_shader_parameter("blast_radius", explosion_radius)
	var wave := create_tween()
	wave.tween_method(_set_wave_progress, 0.0, 1.0, WAVE_DURATION)
	wave.tween_callback(func(): _blast_wave.visible = false)

@rpc("authority", "call_local", "reliable")
func _fx_respawn() -> void:
	_fx_fusing = false
	_dormant = false
	_apply_held_collision()
	for fx: Node3D in [_blast_particles, _blast_wave, _flash]:
		fx.position = Vector3.ZERO

func _set_wave_progress(value: float) -> void:
	_blast_wave.set_instance_shader_parameter("progress", value)

func _update_fuse_fx(delta: float) -> void:
	if not _fx_fusing:
		return
	_fx_fuse_left -= delta
	var t := 1.0 - clampf(_fx_fuse_left / _fx_fuse_total, 0.0, 1.0)
	_fx_clock += delta * lerpf(FUSE_PULSE_HZ_MIN, FUSE_PULSE_HZ_MAX, t)

# --- Base-class hooks --------------------------------------------------------

# The fuse pulse wins over the team glow while lit.
func set_live_glow(team: int, amount: float) -> void:
	if _fx_fusing and _ball_material:
		var t := 1.0 - clampf(_fx_fuse_left / _fx_fuse_total, 0.0, 1.0)
		var pulse := 0.5 + 0.5 * sin(_fx_clock * TAU)
		_ball_material.emission_enabled = true
		_ball_material.emission = FUSE_COLOR
		_ball_material.emission_energy_multiplier = lerpf(0.6, 3.0, t) * pulse
		return
	super(team, amount)

# A dormant ball must stay non-solid even when the held_by sync re-applies collision.
func _apply_held_collision() -> void:
	if _dormant:
		collision_layer = 0
		collision_mask = 0
		return
	super()

# Keep the root visible while dormant (hiding only the shell) so the FX children can finish.
func _update_carry_visibility() -> void:
	ball_mesh.visible = not _dormant
	if _dormant:
		visible = true
		return
	super()
