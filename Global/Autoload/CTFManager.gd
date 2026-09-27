extends Node

# Capture-the-flag detection, host-authoritative. Bases (group "ctf_base") each guard a
# team flag, linked via the base's `flag` export. A team scores by carrying an enemy
# flag into its own base. Detection lives here; scoring is owned by MatchManager so the
# HUD shows it. Inert unless a CTF match is actually being played.

func _physics_process(_delta: float) -> void:
	if not multiplayer.is_server():
		return
	if MatchManager.game_mode != Pedestal.GameMode.CAPTURE_THE_FLAG:
		return
	if MatchManager.state != MatchManager.State.PLAYING:
		return

	var bases := get_tree().get_nodes_in_group("ctf_base")
	for node in bases:
		var base := node as CTFBase
		if base == null or base.flag == null:
			continue
		var flag := base.flag
		if flag.held_by == 0:
			continue
		var holder := _player(flag.held_by)
		if holder == null:
			continue
		# Only an enemy flag scores, and only once the carrier reaches their own base.
		if holder.team == base.team:
			continue
		var home := _home_base(bases, holder.team)
		if home and holder in home.get_overlapping_bodies():
			flag.server_reset()
			MatchManager.server_on_flag_capture(holder.team)
			return

func _home_base(bases: Array, team: int) -> CTFBase:
	for node in bases:
		var base := node as CTFBase
		if base and base.team == team:
			return base
	return null

func _player(id: int) -> Player:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null(str(id)) as Player
