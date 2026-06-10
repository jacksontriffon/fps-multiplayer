extends Area3D
class_name InfiniteHeartZone

# Grants the infinite-hearts effect to players while they stand inside, via the Area3D
# enter/exit signals (no per-frame polling). The effect is generic and source-keyed on
# the Player, so a consumable item or ability can grant it the same way later.

const SOURCE := &"infinite_heart_zone"

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _on_body_entered(body: Node3D) -> void:
	if body is Player:
		body.set_effect(Player.INFINITE_HEARTS, true, SOURCE)

func _on_body_exited(body: Node3D) -> void:
	if body is Player:
		body.set_effect(Player.INFINITE_HEARTS, false, SOURCE)

# Players outlive the map (Game.tscn owns them; the map is swapped underneath), so
# revoke from anyone still inside when the zone is torn down — else it leaks to the next map.
func _exit_tree() -> void:
	for body in get_overlapping_bodies():
		if body is Player:
			body.set_effect(Player.INFINITE_HEARTS, false, SOURCE)
