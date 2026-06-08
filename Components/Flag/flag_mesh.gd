@tool
extends MeshInstance3D
class_name FlagMesh

# The flag's visual: the pole (this node) plus the cloth (FlagFabric child). Owns its
# colour so it can be tinted straight from the inspector and previews live in the editor
# (@tool). The Flag grabbable reuses `color` / set_display_color() to flash the throw tint.

const DEFAULT_COLOR := Color(1, 0.57254905, 0.34901962)

## Flag colour — tints the pole and cloth. Orange by default; set it per flag here.
@export var color: Color = DEFAULT_COLOR:
	set(value):
		color = value
		if is_node_ready():
			_apply_color()

# Owned per-instance materials (pole + cloth) so recolouring one flag never touches others.
var _materials := []

func _ready() -> void:
	_collect_materials()
	_apply_color()

func _collect_materials() -> void:
	_materials.clear()
	for node in [self, get_node_or_null("FlagFabric")]:
		var mi := node as MeshInstance3D
		if mi == null:
			continue
		var src := mi.get_active_material(0)
		var mat: StandardMaterial3D = src.duplicate() if src is StandardMaterial3D else StandardMaterial3D.new()
		mi.material_override = mat
		_materials.append(mat)

func _apply_color() -> void:
	for mat in _materials:
		mat.albedo_color = color

# Flash a colour without changing the base `color` (used for the throw-charge tint).
func set_display_color(c: Color) -> void:
	for mat in _materials:
		mat.albedo_color = c
