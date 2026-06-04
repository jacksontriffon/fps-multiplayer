extends CharacterBody3D
class_name MultiplayerCharacterBody3D

@export var player_camera: Camera3D

func _enter_tree() -> void:
	set_multiplayer_authority(name.to_int())

func _ready() -> void:
	player_camera.current = is_multiplayer_authority()

func _physics_process(delta: float) -> void:
	if !is_multiplayer_authority():
		return
