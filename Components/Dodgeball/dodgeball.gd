extends Grabbable
class_name Dodgeball

# A dodgeball: the visible, throwable ball. Plain by default. Special behaviour lives in
# optional child component nodes — an Explosive child turns it into a grenade — which this
# script forwards its grab/throw/reset/hit lifecycle to and reads its look back from. The
# ball owns the material; components only describe what colour/emission it should wear.

const CHARGE_COLOR := Color(0.9, 0.1, 0.1)

# Peak emission for a fully-lit live glow; low for a subtle tell.
const LIVE_GLOW_ENERGY := 0.8

@onready var outline_mesh = %OutlineMesh
@onready var ball_mesh: MeshInstance3D = $CollisionShape3D/BallMesh
@onready var _explosive: Explosive = get_node_or_null("Explosive") as Explosive

var _ball_material: StandardMaterial3D
var _base_color := Color.WHITE
var _glow_color := Color.BLACK

func _ready() -> void:
	super()
	# Own a per-instance material so tinting one ball doesn't touch the others.
	var src := ball_mesh.get_active_material(0)
	_ball_material = src.duplicate() if src is StandardMaterial3D else StandardMaterial3D.new()
	_base_color = _ball_material.albedo_color
	ball_mesh.material_override = _ball_material

# --- Lifecycle, forwarded to behaviour components ----------------------------

func grab(peer_id: int, slot: int) -> bool:
	var grabbed := super(peer_id, slot)
	if grabbed and _explosive:
		_explosive.on_grabbed(peer_id)
	return grabbed

func throw(direction: Vector3, power: float = 1.0) -> void:
	super(direction, power)  # stamps thrower_id before the component reads it
	if _explosive:
		_explosive.on_thrown()

func server_reset() -> void:
	super()
	if _explosive:
		_explosive.on_reset()

# Let a live bomb's blast do the damage instead of the normal shove.
func _server_check_hit(delta: float) -> void:
	if _explosive and _explosive.suppresses_normal_hit():
		return
	super(delta)

# --- Base-class hooks --------------------------------------------------------

func toggle_highlight(is_highlighted: bool) -> void:
	outline_mesh.visible = is_highlighted

# Charge reddens the ball over its current base (the armed shell when a bomb).
func set_charge_visual(tint_amount: float) -> void:
	if _ball_material:
		var base := _explosive.base_albedo(_base_color) if _explosive else _base_color
		_ball_material.albedo_color = base.lerp(CHARGE_COLOR, tint_amount)

# Visual-only sphere (its own material, no outline/physics) for the inventory preview.
func get_preview_visual() -> Node3D:
	var preview := MeshInstance3D.new()
	preview.mesh = ball_mesh.mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _explosive.base_albedo(_base_color) if _explosive else _base_color
	preview.material_override = mat
	return preview

# Emission: a behaviour component (e.g. a lit/armed bomb) overrides it; otherwise the
# team glow of a live thrown ball. Colour holds from the last live frame as it fades.
func set_live_glow(team: int, amount: float) -> void:
	if _ball_material == null:
		return
	if _explosive:
		var e := _explosive.emission_override()
		if not e.is_empty():
			_ball_material.emission_enabled = true
			_ball_material.emission = e["color"]
			_ball_material.emission_energy_multiplier = e["energy"]
			return
	if team >= 0 and team < Player.TEAM_COLORS.size():
		_glow_color = Player.TEAM_COLORS[team]
	_ball_material.emission_enabled = amount > 0.001
	_ball_material.emission = _glow_color
	_ball_material.emission_energy_multiplier = amount * LIVE_GLOW_ENERGY

# A dormant (mid-explosion) ball must stay non-solid even when held_by re-applies collision.
func _apply_held_collision() -> void:
	if _explosive and _explosive.is_dormant():
		collision_layer = 0
		collision_mask = 0
		return
	super()

# Keep the root visible while dormant (hiding only the shell) so the FX can finish.
func _update_carry_visibility() -> void:
	var dormant := _explosive != null and _explosive.is_dormant()
	ball_mesh.visible = not dormant
	if dormant:
		visible = true
		return
	super()
