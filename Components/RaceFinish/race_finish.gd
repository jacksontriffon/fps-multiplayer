extends Area3D
class_name RaceFinish

# The race goal line. The first racer to touch it wins the match (server-authoritative; see
# MatchManager.server_on_race_finish). Inert in every other mode. Detection fires on every peer
# because player bodies replicate, but only the server decides the winner. Players are on
# physics layer 1 (see AbilityOrb), which the mask watches.

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node3D) -> void:
	if not multiplayer.is_server() or body is not Player:
		return
	MatchManager.server_on_race_finish(body.name.to_int())
