extends Node3D
class_name SpawnPoints

# Drop into any map. Add SpawnPoint scenes anywhere underneath and set each one's `team` in
# the inspector. The manager buckets them by team through the "spawn_point" group, so layout
# is free-form — no fixed Team1/Team2 node structure required. Only points under THIS manager
# are used, so each map's manager owns its own spawns after a map swap.

var _team_of: Dictionary = {}
var _slot_of: Dictionary = {}

func _ready() -> void:
	add_to_group("spawn_points")

# Assign id a team + slot and return its spawn transform. Idempotent per id. Pass
# preferred_team >= 0 to pin the team (used on respawn to keep a player's team stable across a
# map swap); -1 balances onto the least-full team.
func reserve(id: int, preferred_team := -1) -> Dictionary:
	var buckets := _buckets()
	if not _team_of.has(id):
		var team := preferred_team if preferred_team >= 0 else _choose_team(buckets)
		# Pick the slot before recording the id: _next_free_slot scans _team_of, so a
		# half-inserted entry (team set, slot not yet) would read a missing _slot_of key.
		var slot := _next_free_slot(team)
		_team_of[id] = team
		_slot_of[id] = slot
	elif preferred_team >= 0 and preferred_team != _team_of[id]:
		var slot := _next_free_slot(preferred_team)
		_team_of[id] = preferred_team
		_slot_of[id] = slot
	var marker := _marker(buckets, _team_of[id], _slot_of[id])
	return {
		"team": _team_of[id],
		"position": marker.global_position if marker else global_position,
		"yaw": marker.global_rotation.y if marker else 0.0,
	}

func release(id: int) -> void:
	_team_of.erase(id)
	_slot_of.erase(id)

# Hand out any free spawn under this manager, ignoring teams. Used by teamless maps like the
# lobby, where players have no side yet. Idempotent per id; the returned team is -1 (none).
func reserve_any(id: int) -> Dictionary:
	var points := _all_points()
	if not _slot_of.has(id):
		_team_of[id] = -1
		_slot_of[id] = _next_free_any_slot()
	if points.is_empty():
		push_warning("SpawnPoints: no spawn points")
		return {"team": -1, "position": global_position, "yaw": 0.0}
	var marker: Marker3D = points[_slot_of[id] % points.size()]
	return {"team": -1, "position": marker.global_position, "yaw": marker.global_rotation.y}

# All SpawnPoints under this manager, sorted by name for stable slot ordering.
func _all_points() -> Array:
	var pts := []
	for node in get_tree().get_nodes_in_group("spawn_point"):
		if is_ancestor_of(node) and node is SpawnPoint:
			pts.append(node)
	pts.sort_custom(func(a, b): return a.name < b.name)
	return pts

# team -> Array[SpawnPoint], limited to points under this manager (name-sorted via _all_points).
func _buckets() -> Dictionary:
	var buckets := {}
	for sp in _all_points():
		if not buckets.has(sp.team):
			buckets[sp.team] = []
		buckets[sp.team].append(sp)
	return buckets

# Least-full team among those that actually have spawn points; ties favour the lower team.
func _choose_team(buckets: Dictionary) -> int:
	var teams := buckets.keys()
	teams.sort()
	var counts := {}
	for pid in _team_of:
		counts[_team_of[pid]] = int(counts.get(_team_of[pid], 0)) + 1
	var best := -1
	var best_count := 0
	for team in teams:
		var c := int(counts.get(team, 0))
		if best == -1 or c < best_count:
			best = team
			best_count = c
	return best if best >= 0 else 0

# Lowest slot index not used by any reserved id (across all teams), for the teamless pool.
func _next_free_any_slot() -> int:
	var used := {}
	for pid in _slot_of:
		used[_slot_of[pid]] = true
	var i := 0
	while used.has(i):
		i += 1
	return i

func _next_free_slot(team: int) -> int:
	var used := {}
	for pid in _team_of:
		if _team_of[pid] == team:
			used[_slot_of[pid]] = true
	var i := 0
	while used.has(i):
		i += 1
	return i

func _marker(buckets: Dictionary, team: int, slot: int) -> Marker3D:
	var points: Array = buckets.get(team, [])
	if points.is_empty():
		push_warning("SpawnPoints: no spawn points for team %d" % team)
		return null
	return points[slot % points.size()]
