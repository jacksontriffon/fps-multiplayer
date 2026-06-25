extends MeshInstance3D
class_name CreativeHighlight

# Translucent box that wraps the body the creative crosshair is on. Eases in when targeted and out
# when not, sizing itself to the target's world bounds. Purely a local visual — the CreativeMode
# controller owns it and calls target()/clear(); the fade runs here.

const GROW := 1.04           # box scale over the target's bounds, so the outline reads outside it
const ALPHA := 0.25          # peak translucency
const EMISSION := 0.6        # peak emission energy
const FADE_SPEED := 6.0      # alpha per second
const TINT := Color(0.3, 0.8, 1.0)

var _mat: StandardMaterial3D
var _target: Node3D = null
var _alpha := 0.0

func _ready() -> void:
	top_level = true  # ignore the player's transform; we drive our own world placement
	visible = false
	mesh = BoxMesh.new()
	_mat = StandardMaterial3D.new()
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.albedo_color = Color(TINT, 0.0)
	_mat.emission_enabled = true
	_mat.emission = TINT
	_mat.emission_energy_multiplier = 0.0
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = _mat

# Wrap `node` (or stop wrapping when null). Repositions/resizes to the node's bounds immediately; the
# alpha follows in _process so it eases in and out.
func target(node: Node3D) -> void:
	_target = node
	if node == null or not is_instance_valid(node):
		return
	var aabb := _node_aabb(node)
	(mesh as BoxMesh).size = aabb.size * GROW
	var b := node.global_transform.basis.orthonormalized()
	global_transform = Transform3D(b, node.global_transform * aabb.get_center())

# Hide instantly with no fade (leaving creative mode).
func clear() -> void:
	_target = null
	_alpha = 0.0
	visible = false

func _process(delta: float) -> void:
	var want := 1.0 if (_target != null and is_instance_valid(_target)) else 0.0
	_alpha = move_toward(_alpha, want, FADE_SPEED * delta)
	if _alpha <= 0.001:
		visible = false
		return
	visible = true
	_mat.albedo_color.a = ALPHA * _alpha
	_mat.emission_energy_multiplier = EMISSION * _alpha

# Local-space bounds: the node's own AABB if it's visual, otherwise the merged bounds of its visual
# descendants (for bodies whose meshes are children).
func _node_aabb(node: Node3D) -> AABB:
	if node is VisualInstance3D:
		return (node as VisualInstance3D).get_aabb()
	var combined := AABB()
	var has := false
	var inv := node.global_transform.affine_inverse()
	for child in node.find_children("*", "VisualInstance3D", true, false):
		var local := inv * (child as Node3D).global_transform * (child as VisualInstance3D).get_aabb()
		if has:
			combined = combined.merge(local)
		else:
			combined = local
			has = true
	return combined if has else AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
