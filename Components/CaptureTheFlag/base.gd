@tool
extends Area3D
class_name CTFBase

# A team's home base. Reusable across maps: drop it in, set `team`, and point `flag` at
# this team's flag node (place the flag separately so bases and flags move independently).
# The base owns its team's colour: the pad, label and the linked flag all take it. The Area
# detects bodies on every peer, but only the host acts on it — the CTFManager autoload polls
# get_overlapping_bodies(). @tool so everything recolors in the editor as you change `team`.

const TEAM_COLORS := [Color.RED, Color.BLUE]
const TEAM_NAMES := ["Red", "Blue"]

@export var team: int = 0:
	set(value):
		team = value
		_apply_visuals()

## This base's flag (a Flag node placed in the map). Carry the enemy's flag here to score.
@export var flag: Flag:
	set(value):
		flag = value
		_apply_visuals()

@onready var pad: MeshInstance3D = $Pad
@onready var label: Label3D = $Label

func _ready() -> void:
	_apply_visuals()
	if Engine.is_editor_hint():
		return
	add_to_group("ctf_base")

# Only show the base while Capture the Flag is the active match; hidden in the lobby and
# other modes. Detection is owned by CTFManager (also mode-gated), so visuals are all that
# need toggling here.
func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	visible = MatchManager.is_mode_active(Pedestal.GameMode.CAPTURE_THE_FLAG)

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
	# Drive the linked flag's colour. Reach its mesh directly (a @tool node): flag.gd isn't
	# @tool, so it's a placeholder in the editor and its methods can't be called there.
	if flag:
		var mesh := flag.get_node_or_null("CollisionShape3D/FlagMesh") as FlagMesh
		if mesh:
			mesh.color = color
