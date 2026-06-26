extends Node3D
class_name CreativeGizmo

# Translate gizmo drawn on an editable body while it's within hands reach: three world-axis arrows
# (X red, Y green, Z blue) plus a center box you grab to move freely. The CreativeMode controller
# owns one per nearby body, calls update_placement() each frame, pick()s the arm under the crosshair
# and set_hover()s it. Picking + the axis math live here; CreativeMode drives the actual movement.

enum { HANDLE_NONE = -1, HANDLE_CENTER = 0, HANDLE_X = 1, HANDLE_Y = 2, HANDLE_Z = 3 }

const INNER_FRAC := 0.18     # arms start this far out, so the crowded base doesn't fight the center
const HEAD_LEN_FRAC := 0.28  # cone head as a fraction of arm length
const SHAFT_RADIUS_FRAC := 0.025
const HEAD_RADIUS_FRAC := 0.07
const CENTER_FRAC := 0.13     # center box edge as a fraction of arm length
const PICK_FRAC := 0.16       # ray-to-arm pick tolerance (world units, scaled by arm length)
const ARM_MIN := 0.6
const ARM_MAX := 2.2

const COL_X := Color(1.0, 0.30, 0.34)
const COL_Y := Color(0.46, 0.92, 0.30)
const COL_Z := Color(0.32, 0.56, 1.0)
const COL_CENTER := Color(0.92, 0.92, 0.95)

var _node: Node3D = null
var _local_center := Vector3.ZERO
var _arm_len := 1.0
var _pick_r := 0.16
var _center_r := 0.18
var _hover := HANDLE_NONE
var _mats := {}   # handle -> Array[StandardMaterial3D]
var _base := {}   # handle -> Color

func _ready() -> void:
	top_level = true  # we drive our own world placement, ignoring the player's transform

# Build the arrows + center handle sized to `node`'s bounds and remember the body we track.
func attach(node: Node3D) -> void:
	_node = node
	var aabb := local_aabb(node)
	_local_center = aabb.get_center()
	_arm_len = clampf((aabb.size * 0.5).length() * 1.25, ARM_MIN, ARM_MAX)
	_pick_r = _arm_len * PICK_FRAC
	_center_r = _arm_len * (CENTER_FRAC * 0.5 + 0.06)
	_build_arm(HANDLE_X, Vector3.RIGHT, COL_X)
	_build_arm(HANDLE_Y, Vector3.UP, COL_Y)
	_build_arm(HANDLE_Z, Vector3.BACK, COL_Z)
	_build_center()
	set_hover(HANDLE_NONE)

func target_node() -> Node3D:
	return _node

func has_valid_target() -> bool:
	return is_instance_valid(_node)

# Sit at the body's bounds center, oriented to world axes (a global-space translate gizmo).
func update_placement() -> void:
	if not is_instance_valid(_node):
		return
	global_transform = Transform3D(Basis.IDENTITY, _node.global_transform * _local_center)

# World-space direction of an axis handle.
func axis_dir(handle: int) -> Vector3:
	match handle:
		HANDLE_X: return Vector3.RIGHT
		HANDLE_Y: return Vector3.UP
		HANDLE_Z: return Vector3.BACK
		_: return Vector3.ZERO

# Closest handle to the view ray, as {handle, dist}; dist is the ray's perpendicular gap to that
# handle (smaller = better) so CreativeMode can pick the nearest across every gizmo. The center box
# is only offered when the ray passes very close, so arms win whenever you're aiming at one.
func pick(from: Vector3, dir: Vector3) -> Dictionary:
	var o := global_position
	var best := HANDLE_NONE
	var best_dist := INF
	for handle in [HANDLE_X, HANDLE_Y, HANDLE_Z]:
		var a := o + axis_dir(handle) * (_arm_len * INNER_FRAC)
		var b := o + axis_dir(handle) * _arm_len
		var d := _ray_segment_dist(from, dir, a, b)
		if d <= _pick_r and d < best_dist:
			best_dist = d
			best = handle
	var cd := _ray_point_dist(from, dir, o)
	if cd <= _center_r and cd < best_dist:
		best_dist = cd
		best = HANDLE_CENTER
	return {"handle": best, "dist": best_dist}

# Brighten the hovered handle (HANDLE_NONE clears all).
func set_hover(handle: int) -> void:
	_hover = handle
	for h in _mats:
		var col: Color = _base[h]
		if h == handle:
			col = col.lerp(Color.WHITE, 0.65)
		for mat in _mats[h]:
			mat.albedo_color = col

# --- Geometry --------------------------------------------------------------

func _build_arm(handle: int, axis: Vector3, color: Color) -> void:
	var arm := Node3D.new()
	arm.basis = _axis_basis(axis)  # maps local +Y onto the axis
	add_child(arm)
	var head_len := _arm_len * HEAD_LEN_FRAC
	var inner := _arm_len * INNER_FRAC
	var shaft_top := _arm_len - head_len
	var mats: Array = []

	var shaft := MeshInstance3D.new()
	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = _arm_len * SHAFT_RADIUS_FRAC
	shaft_mesh.bottom_radius = _arm_len * SHAFT_RADIUS_FRAC
	shaft_mesh.height = shaft_top - inner
	shaft.mesh = shaft_mesh
	shaft.position.y = (inner + shaft_top) * 0.5
	var shaft_mat := _make_mat(color)
	shaft.material_override = shaft_mat
	mats.append(shaft_mat)
	arm.add_child(shaft)

	var head := MeshInstance3D.new()
	var head_mesh := CylinderMesh.new()
	head_mesh.top_radius = 0.0
	head_mesh.bottom_radius = _arm_len * HEAD_RADIUS_FRAC
	head_mesh.height = head_len
	head.mesh = head_mesh
	head.position.y = _arm_len - head_len * 0.5
	var head_mat := _make_mat(color)
	head.material_override = head_mat
	mats.append(head_mat)
	arm.add_child(head)

	_mats[handle] = mats
	_base[handle] = color

func _build_center() -> void:
	var box := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	var s := _arm_len * CENTER_FRAC
	mesh.size = Vector3(s, s, s)
	box.mesh = mesh
	var mat := _make_mat(COL_CENTER)
	box.material_override = mat
	add_child(box)
	_mats[HANDLE_CENTER] = [mat]
	_base[HANDLE_CENTER] = COL_CENTER

func _make_mat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.no_depth_test = true  # always visible, even through the body it sits on
	mat.render_priority = 8
	return mat

# Basis whose +Y points along `axis` (cylinders are authored Y-up).
func _axis_basis(axis: Vector3) -> Basis:
	if axis == Vector3.UP:
		return Basis.IDENTITY
	if axis == Vector3.RIGHT:
		return Basis(Vector3.BACK, -PI * 0.5)
	return Basis(Vector3.RIGHT, PI * 0.5)  # Vector3.BACK (+Z)

# --- Math ------------------------------------------------------------------

func _ray_point_dist(from: Vector3, dir: Vector3, p: Vector3) -> float:
	var t := maxf((p - from).dot(dir), 0.0)
	return (from + dir * t).distance_to(p)

# Shortest distance between a ray (from, unit dir) and a segment [a, b].
func _ray_segment_dist(from: Vector3, dir: Vector3, a: Vector3, b: Vector3) -> float:
	var u := b - a
	var w := a - from
	var uu := u.dot(u)
	var ud := u.dot(dir)
	var uw := u.dot(w)
	var dw := dir.dot(w)
	var denom := uu - ud * ud
	var sc := 0.0
	if absf(denom) > 1e-6:
		sc = clampf((ud * dw - uw) / denom, 0.0, 1.0)
	var pseg := a + u * sc
	var t := maxf((pseg - from).dot(dir), 0.0)
	return (from + dir * t).distance_to(pseg)

# Local-space bounds: the node's own AABB if visual, else the merged bounds of its visual
# descendants. (Mirrors CreativeHighlight so gizmo + outline size to the same box.)
static func local_aabb(node: Node3D) -> AABB:
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
