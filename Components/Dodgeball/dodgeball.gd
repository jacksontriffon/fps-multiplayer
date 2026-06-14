extends Grabbable
class_name Dodgeball

# A dodgeball. Plain by default; an "armed" dodgeball detonates after a fuse and/or on
# impact like a grenade. A ball is armed at grab time when its grabber carries the bomb
# upgrade (Player.BOMB_CONTAINER), or permanently for an authored bomb pickup
# (permanent_armed). The server owns all explosion logic (fuse, blast, respawn); clients
# only play the synced FX. The blast FX are built in code (see _build_blast_fx) so every
# dodgeball can explode without authoring the nodes in each scene.

const CHARGE_COLOR := Color(0.9, 0.1, 0.1)

# Peak emission for a fully-lit live glow; low for a subtle tell.
const LIVE_GLOW_ENERGY := 0.8

# Armed look: the ball darkens to a metallic shell with a low menacing glow, so a live
# bomb reads differently from a normal ball in the hand.
const ARMED_COLOR := Color(0.13, 0.13, 0.16)
const ARMED_EMISSION := Color(1.0, 0.25, 0.05)
const ARMED_GLOW_ENERGY := 0.6

# --- Explosion tuning (used only while armed) --------------------------------
## Authored bomb pickup: starts (and respawns) armed instead of needing the upgrade.
@export var permanent_armed := false
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

## True while this ball is a live bomb. Server-authoritative, replicated so every peer
## shows the armed look. Set at grab time for upgrade carriers; reset to permanent_armed
## on respawn so an upgrade ball reverts to a normal ball once it's done.
@export var armed := false

const WAVE_DURATION := 0.6
const FLASH_DURATION := 0.35
const FLASH_ENERGY := 8.0
const FUSE_PULSE_HZ_MIN := 2.0
const FUSE_PULSE_HZ_MAX := 12.0
const FUSE_COLOR := Color(1.0, 0.25, 0.05)

@onready var outline_mesh = %OutlineMesh
@onready var ball_mesh: MeshInstance3D = $CollisionShape3D/BallMesh

var _ball_material: StandardMaterial3D
var _base_color := Color.WHITE
var _glow_color := Color.BLACK

# Blast FX, built in code so any dodgeball can detonate. Present on every peer (built in
# _ready) and driven by the explode/respawn RPCs.
var _blast_particles: GPUParticles3D
var _blast_wave: MeshInstance3D
var _flash: OmniLight3D

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

func _ready() -> void:
	super()
	# Own a per-instance material so tinting one ball doesn't touch the others.
	var src := ball_mesh.get_active_material(0)
	_ball_material = src.duplicate() if src is StandardMaterial3D else StandardMaterial3D.new()
	_base_color = _ball_material.albedo_color
	ball_mesh.material_override = _ball_material
	_build_blast_fx()
	armed = permanent_armed

func _physics_process(delta: float) -> void:
	super(delta)
	if not multiplayer.has_multiplayer_peer():
		return
	_update_fuse_fx(delta)
	if is_multiplayer_authority():
		_server_update_explosion(delta)

# --- Authority-only ----------------------------------------------------------

func grab(peer_id: int, slot: int) -> bool:
	var grabbed := super(peer_id, slot)
	if grabbed:
		# A grabber carrying the bomb upgrade arms whatever they pick up.
		if not armed:
			var holder := get_tree().current_scene.get_node_or_null(str(peer_id)) as Player
			if holder and holder.has_effect(Player.BOMB_CONTAINER):
				armed = true
		if armed:
			_impact_armed = false  # caught — but a lit fuse keeps burning
	return grabbed

func throw(direction: Vector3, power: float = 1.0) -> void:
	if not armed:
		super(direction, power)
		return
	_armed_thrower = held_by
	super(direction, power)
	_armed_age = 0.0
	_impact_armed = explode_on_impact
	# A re-thrown lit ball keeps its original countdown (hot potato).
	if fuse_time > 0.0 and _fuse_left < 0.0:
		_fuse_left = fuse_time
		_fx_arm.rpc(fuse_time)

func server_reset() -> void:
	if not is_multiplayer_authority():
		return
	_fuse_left = -1.0
	_impact_armed = false
	_armed_age = 0.0
	_armed_thrower = 0
	armed = permanent_armed
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
		var to_victim := player.global_position - center
		var dist := to_victim.length()
		if dist > explosion_radius:
			continue
		# Closer = harder shove, aimed away from the blast centre plus an upward pop.
		var falloff := pow(1.0 - dist / explosion_radius, falloff_power)
		var strength := lerpf(knockback_edge, knockback_center, falloff)
		var away := to_victim / dist if dist > 0.01 else Vector3.UP
		var impulse := (away + Vector3.UP * upward_boost).normalized() * strength
		# A strong blast knocks victims down; weaker edge shoves just push them.
		var is_knockdown := strength >= knockback_center * 0.5
		MatchManager.server_resolve_hit(victim_id, _armed_thrower, impulse, is_knockdown, costs_a_life, true)
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
	armed = permanent_armed
	_fx_respawn.rpc()

# --- FX, runs on every peer --------------------------------------------------

# Build the blast FX in code so every dodgeball owns them without per-scene authoring.
func _build_blast_fx() -> void:
	var fire := Gradient.new()
	fire.offsets = PackedFloat32Array([0.0, 0.25, 0.6, 1.0])
	fire.colors = PackedColorArray([
		Color(1.0, 0.95, 0.7, 1.0), Color(1.0, 0.55, 0.1, 1.0),
		Color(0.8, 0.15, 0.02, 0.8), Color(0.2, 0.2, 0.2, 0.0)])
	var fire_tex := GradientTexture1D.new()
	fire_tex.gradient = fire
	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(1.0, 0.0))
	var shrink_tex := CurveTexture.new()
	shrink_tex.curve = shrink
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.3
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.spread = 180.0
	pm.initial_velocity_min = 6.0
	pm.initial_velocity_max = 14.0
	pm.gravity = Vector3(0, -4, 0)
	pm.damping_min = 2.0
	pm.damping_max = 5.0
	pm.scale_min = 0.5
	pm.scale_max = 1.4
	pm.scale_curve = shrink_tex
	pm.color_ramp = fire_tex
	var puff_mat := StandardMaterial3D.new()
	puff_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff_mat.vertex_color_use_as_albedo = true
	puff_mat.disable_receive_shadows = true
	puff_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	puff_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	puff_mat.billboard_keep_scale = true
	var puff := QuadMesh.new()
	puff.size = Vector2(0.5, 0.5)
	puff.material = puff_mat
	_blast_particles = GPUParticles3D.new()
	_blast_particles.emitting = false
	_blast_particles.amount = 48
	_blast_particles.lifetime = 0.9
	_blast_particles.one_shot = true
	_blast_particles.explosiveness = 1.0
	_blast_particles.process_material = pm
	_blast_particles.draw_pass_1 = puff
	add_child(_blast_particles)

	var wave_mesh := SphereMesh.new()
	wave_mesh.radius = 1.0
	wave_mesh.height = 2.0
	var wave_mat := ShaderMaterial.new()
	wave_mat.shader = preload("res://Components/Dodgeball/explosion.gdshader")
	_blast_wave = MeshInstance3D.new()
	_blast_wave.visible = false
	_blast_wave.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_blast_wave.mesh = wave_mesh
	_blast_wave.material_override = wave_mat
	add_child(_blast_wave)

	_flash = OmniLight3D.new()
	_flash.light_color = Color(1.0, 0.6, 0.3)
	_flash.light_energy = 0.0
	_flash.omni_range = 9.0
	add_child(_flash)

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

func toggle_highlight(is_highlighted: bool) -> void:
	outline_mesh.visible = is_highlighted

# Charge reddens the ball over its current base (the armed shell when armed).
func set_charge_visual(tint_amount: float) -> void:
	if _ball_material:
		var base := ARMED_COLOR if armed else _base_color
		_ball_material.albedo_color = base.lerp(CHARGE_COLOR, tint_amount)

# Visual-only sphere (its own material, no outline/physics) for the inventory preview.
func get_preview_visual() -> Node3D:
	var preview := MeshInstance3D.new()
	preview.mesh = ball_mesh.mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ARMED_COLOR if armed else _base_color
	preview.material_override = mat
	return preview

# Emission, in priority order: the fuse pulse while lit, then a steady armed glow, then
# the team glow of a live thrown ball. Colour holds from the last live frame as it fades.
func set_live_glow(team: int, amount: float) -> void:
	if _ball_material == null:
		return
	if _fx_fusing:
		var t := 1.0 - clampf(_fx_fuse_left / _fx_fuse_total, 0.0, 1.0)
		var pulse := 0.5 + 0.5 * sin(_fx_clock * TAU)
		_ball_material.emission_enabled = true
		_ball_material.emission = FUSE_COLOR
		_ball_material.emission_energy_multiplier = lerpf(0.6, 3.0, t) * pulse
		return
	if armed:
		_ball_material.emission_enabled = true
		_ball_material.emission = ARMED_EMISSION
		_ball_material.emission_energy_multiplier = ARMED_GLOW_ENERGY
		return
	if team >= 0 and team < Player.TEAM_COLORS.size():
		_glow_color = Player.TEAM_COLORS[team]
	_ball_material.emission_enabled = amount > 0.001
	_ball_material.emission = _glow_color
	_ball_material.emission_energy_multiplier = amount * LIVE_GLOW_ENERGY

# A dormant ball must stay non-solid even when the held_by sync re-applies collision.
func _apply_held_collision() -> void:
	if _dormant:
		collision_layer = 0
		collision_mask = 0
		return
	super()

# Keep the root visible while dormant (hiding only the shell) so the FX can finish.
func _update_carry_visibility() -> void:
	ball_mesh.visible = not _dormant
	if _dormant:
		visible = true
		return
	super()
