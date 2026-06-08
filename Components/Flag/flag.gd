extends Grabbable
class_name Flag

# A Grabbable flag: grab, carry and throw all come from Grabbable. The colour lives on the
# FlagMesh (set it there); here we only flash it toward CHARGE_COLOR on throw wind-up.

const CHARGE_COLOR := Color(0.9, 0.1, 0.1)

@onready var outline_mesh = %OutlineMesh
@onready var flag_mesh: FlagMesh = $CollisionShape3D/FlagMesh

func _ready() -> void:
	super()
	add_to_group("flag")

func toggle_highlight(is_highlighted: bool) -> void:
	outline_mesh.visible = is_highlighted

func set_charge_visual(tint_amount: float) -> void:
	if flag_mesh:
		flag_mesh.set_display_color(flag_mesh.color.lerp(CHARGE_COLOR, tint_amount))
