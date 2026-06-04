extends Grabbable
class_name Dodgeball

@onready var outline_mesh = %OutlineMesh

func toggle_highlight(is_highlighted: bool) -> void:
	outline_mesh.visible = is_highlighted
