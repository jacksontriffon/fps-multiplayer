extends CharacterBody3D
class_name MultiplayerCharacterBody3D

func _enter_tree() -> void:
	set_multiplayer_authority(name.to_int())

func _physics_process(delta: float) -> void:
	if !is_multiplayer_authority():
		return
