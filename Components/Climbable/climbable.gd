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

# Quick fade for the billboard prompt as the local player enters/leaves range.
const PROMPT_LERP := 16.0

@onready var rope_mesh: MeshInstance3D = $RopeMesh
@onready var prompt: Label3D = $Prompt

var _material: StandardMaterial3D

func _ready() -> void:
	_setup_material()
	_apply_texture()
	if Engine.is_editor_hint():
		return
	prompt.modulate.a = 0.0
	prompt.outline_modulate.a = 0.0
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

# Show "Climb rope" only to the local player, and only while they're in range and not
# already on the rope (mirrors the Pedestal prompt).
func _process(delta: float) -> void:
	if Engine.is_editor_hint() or prompt == null:
		return
	var show_prompt := _local_can_climb()
	var a := lerpf(prompt.modulate.a, 1.0 if show_prompt else 0.0, delta * PROMPT_LERP)
	prompt.modulate.a = a
	prompt.outline_modulate.a = a

func _local_can_climb() -> bool:
	var p := _local_player() as Player
	if p == null or p not in get_overlapping_bodies():
		return false
	return not p.is_climbing()

func _local_player() -> Node3D:
	if not multiplayer.has_multiplayer_peer():
		return null
	return get_tree().current_scene.get_node_or_null(str(multiplayer.get_unique_id()))

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
