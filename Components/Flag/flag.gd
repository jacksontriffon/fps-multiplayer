extends Grabbable
class_name Flag

# The capture-the-flag objective. It's just a Grabbable cube: grabbing, carrying and
# throwing all come from Grabbable unchanged — only the look differs from a dodgeball.

const CHARGE_COLOR := Color(0.9, 0.1, 0.1)

@onready var outline_mesh = %OutlineMesh
@onready var flag_mesh: MeshInstance3D = $CollisionShape3D/FlagMesh

var _flag_material: StandardMaterial3D
var _base_color := Color.WHITE

func _ready() -> void:
	super()
	add_to_group("flag")
	# Own a per-instance material so charge tinting stays on this flag.
	var src := flag_mesh.get_active_material(0)
	_flag_material = src.duplicate() if src is StandardMaterial3D else StandardMaterial3D.new()
	_base_color = _flag_material.albedo_color
	flag_mesh.material_override = _flag_material

func toggle_highlight(is_highlighted: bool) -> void:
	outline_mesh.visible = is_highlighted

func set_charge_visual(tint_amount: float) -> void:
	if _flag_material:
		_flag_material.albedo_color = _base_color.lerp(CHARGE_COLOR, tint_amount)
