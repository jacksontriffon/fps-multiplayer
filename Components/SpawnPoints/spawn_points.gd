extends Node3D
class_name SpawnPoints

# Drop into any map. Each direct child is a team; each Marker3D under a team is a
# spawn slot. Add teams or markers in the editor and the logic adapts.

var _team_of: Dictionary = {}
var _slot_of: Dictionary = {}

func reserve(id: int) -> Dictionary:
	var team := _choose_team()
	var slot := _next_free_slot(team)
	_team_of[id] = team
	_slot_of[id] = slot
	var marker := _marker(team, slot)
	return {
		"team": team,
		"position": marker.global_position if marker else global_position,
		"yaw": marker.global_rotation.y if marker else 0.0,
	}

func release(id: int) -> void:
	_team_of.erase(id)
	_slot_of.erase(id)

func _choose_team() -> int:
	var counts := PackedInt32Array()
	counts.resize(get_child_count())
	for pid in _team_of:
		counts[_team_of[pid]] += 1
	var best := 0
	for t in range(counts.size()):
		if counts[t] < counts[best]:
			best = t
	return best

func _next_free_slot(team: int) -> int:
	var used := {}
	for pid in _team_of:
		if _team_of[pid] == team:
			used[_slot_of[pid]] = true
	var i := 0
	while used.has(i):
		i += 1
	return i

func _marker(team: int, slot: int) -> Marker3D:
	if team >= get_child_count():
		return null
	var markers := get_child(team).get_children()
	if markers.is_empty():
		push_warning("SpawnPoints: team %d has no markers" % team)
		return null
	return markers[slot % markers.size()]
