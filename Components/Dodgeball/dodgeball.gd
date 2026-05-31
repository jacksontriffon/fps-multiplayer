extends Grabbable
class_name Dodgeball 

@onready var outline_mesh = $BallMesh/OutlineMesh

func _ready() -> void:
	pass


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func toggle_highlight(is_highlighted: bool):
	outline_mesh.visible = is_highlighted
