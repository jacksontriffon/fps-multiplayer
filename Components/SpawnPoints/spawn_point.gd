@tool
extends Marker3D
class_name SpawnPoint

# One team spawn slot. Drop into a map and set `team` in the inspector; the SpawnPoints
# manager buckets these by team through the "spawn_point" group. @tool so the editor label
# recolours with the team the moment you change it. The label is hidden at runtime.

const TEAM_COLORS := [Color.RED, Color.BLUE]
const TEAM_NAMES := ["Red", "Blue"]

@export var team: int = 0:
	set(value):
		team = value
		_apply_label()

@onready var label: Label3D = $TeamLabel

func _ready() -> void:
	_apply_label()
	if Engine.is_editor_hint():
		return
	label.visible = false
	add_to_group("spawn_point")

func _apply_label() -> void:
	if not is_node_ready():
		return
	# team < 0 = a teamless spawn (e.g. the lobby): no side, shown neutral.
	if team < 0:
		label.text = "Spawn"
		label.modulate = Color(0.85, 0.85, 0.85)
		return
	label.text = "%s spawn" % TEAM_NAMES[team % TEAM_NAMES.size()]
	label.modulate = TEAM_COLORS[team % TEAM_COLORS.size()]
