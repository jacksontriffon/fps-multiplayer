@tool
extends Area3D
class_name Climbable

# A climbable surface (a rope here). Any Player inside the Area3D climbs by pushing the
# up/down movement actions — the actual movement lives in Player._update_climb, this node
# just flags who's in range. The rope's look is driven by an exported texture so each
# placement can swap its own material (mirrors FlagMesh's per-instance material).

## Texture wrapped around the rope mesh; tiles along its length. Leave empty for the plain material colour.
@export var texture: Texture2D:
	set(value):
		texture = value
		_apply_texture()

## Metres per second the body travels up or down while climbing this rope.
@export var climb_speed := 3.5

@onready var rope_mesh: MeshInstance3D = $RopeMesh

var _material: StandardMaterial3D

func _ready() -> void:
	_setup_material()
	_apply_texture()
	if Engine.is_editor_hint():
		return
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

# Crosshair prompt fields, read by the HUD when this rope is in reach.
func interact_name() -> String:
	return "Rope"

func interact_action() -> String:
	return "grab"

# Own a per-instance copy of the rope material so swapping one rope's texture never
# touches another placement's.
func _setup_material() -> void:
	if rope_mesh == null:
		return
	var src := rope_mesh.get_active_material(0)
	_material = src.duplicate() if src is StandardMaterial3D else StandardMaterial3D.new()
	rope_mesh.material_override = _material

func _apply_texture() -> void:
	if _material != null:
		_material.albedo_texture = texture

func _on_body_entered(body: Node3D) -> void:
	if body is Player:
		body.set_climb_zone(self, true)

func _on_body_exited(body: Node3D) -> void:
	if body is Player:
		body.set_climb_zone(self, false)

# Players outlive the map, so release anyone still climbing when the rope is torn down
# (mirrors InfiniteHeartZone).
func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	for body in get_overlapping_bodies():
		if body is Player:
			body.set_climb_zone(self, false)
