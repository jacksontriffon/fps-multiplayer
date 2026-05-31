extends Grabbable
class_name Dodgeball 

@onready var outline_mesh = %OutlineMesh

func _ready() -> void:
	pass


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func toggle_highlight(is_highlighted: bool):
	#if outline_mesh == null:
		#outline_mesh = $CollisionShape3D/BallMesh/OutlineMesh
	outline_mesh.visible = is_highlighted
