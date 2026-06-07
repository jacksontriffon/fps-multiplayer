@tool
extends Area3D
class_name CTFBase

# A team's capture zone. Reusable across maps: drop it in, set `team` in the inspector,
# move it where you want. The Area detects bodies on every peer, but only the server
# acts on it — the CaptureTheFlag controller polls get_overlapping_bodies(). @tool so the
# pad/label recolor to the team in the editor as soon as you change `team`.

const TEAM_COLORS := [Color.RED, Color.BLUE]
const TEAM_NAMES := ["Red", "Blue"]

@export var team: int = 0:
	set(value):
		team = value
		_apply_visuals()

@onready var pad: MeshInstance3D = $Pad
@onready var label: Label3D = $Label

func _ready() -> void:
	_apply_visuals()

func _apply_visuals() -> void:
	if not is_node_ready():
		return
	var color: Color = TEAM_COLORS[team % TEAM_COLORS.size()]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.45)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pad.material_override = mat
	label.text = "%s BASE" % TEAM_NAMES[team % TEAM_NAMES.size()]
	label.modulate = color
