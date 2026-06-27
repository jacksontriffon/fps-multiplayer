extends Area3D
class_name OutOfBounds

# A trigger volume sitting below the playable space. When a player falls into it the server
# docks a heart and respawns them at their spawn; a fatal fall eliminates them, mirroring a
# fatal ball hit (see MatchManager.server_player_fell). Detection fires on every peer because
# player bodies replicate, but only the server mutates match state, so the heart loss stays
# authoritative. Players are on physics layer 1 (see AbilityOrb), which the mask watches.

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node3D) -> void:
	if not multiplayer.is_server() or body is not Player:
		return
	MatchManager.server_player_fell(body.name.to_int())
