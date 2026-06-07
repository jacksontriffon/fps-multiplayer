extends Grabbable
class_name Dodgeball

const CHARGE_COLOR := Color(0.9, 0.1, 0.1)

# Peak emission for a fully-lit live glow; low for a subtle tell.
const LIVE_GLOW_ENERGY := 0.8

@onready var outline_mesh = %OutlineMesh
@onready var ball_mesh: MeshInstance3D = $CollisionShape3D/BallMesh

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

func toggle_highlight(is_highlighted: bool) -> void:
	outline_mesh.visible = is_highlighted

func set_charge_visual(tint_amount: float) -> void:
	if _ball_material:
		_ball_material.albedo_color = _base_color.lerp(CHARGE_COLOR, tint_amount)

# Visual-only sphere (its own material, no outline/physics) for the inventory preview.
func get_preview_visual() -> Node3D:
	var preview := MeshInstance3D.new()
	preview.mesh = ball_mesh.mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _base_color
	preview.material_override = mat
	return preview

# Emissive team glow while live; colour holds from the last live frame as it fades.
func set_live_glow(team: int, amount: float) -> void:
	if _ball_material == null:
		return
	if team >= 0 and team < Player.TEAM_COLORS.size():
		_glow_color = Player.TEAM_COLORS[team]
	_ball_material.emission_enabled = amount > 0.001
	_ball_material.emission = _glow_color
	_ball_material.emission_energy_multiplier = amount * LIVE_GLOW_ENERGY
