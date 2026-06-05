extends Node

# Server-authoritative match flow. The host owns all state and pushes snapshots to
# clients via _sync; the HUD only reads them.

enum State { WAITING, PLAYING, ROUND_OVER, MATCH_OVER }

const STARTING_LIVES := 3
const WIN_SCORE := 5
const TEAM_COUNT := 2
const MIN_PER_TEAM := 1
const ROUND_RESET_DELAY := 3.0
const MATCH_RESET_DELAY := 6.0
const TEAM_NAMES := ["Red", "Blue"]

var state: int = State.WAITING
var team_scores := [0, 0]
var lives := {}
var round_num := 0
var status_text := ""

var _team_of := {}
var _reset_token := 0

func server_player_ready(id: int, team: int) -> void:
	if not multiplayer.is_server():
		return
	_team_of[id] = team
	if not lives.has(id):
		lives[id] = 0
	if state != State.WAITING:
		_set_spectator(id, true)
	_broadcast()

# Host-only: kick off a fresh match once both teams have enough players.
func server_request_start() -> void:
	if not multiplayer.is_server() or not can_start():
		return
	team_scores = [0, 0]
	round_num = 0
	_start_round()

func can_start() -> bool:
	return state == State.WAITING and _both_teams_present()

func get_team_counts() -> Array:
	return _team_player_counts()

func server_player_left(id: int) -> void:
	if not multiplayer.is_server():
		return
	_team_of.erase(id)
	lives.erase(id)
	if state == State.PLAYING:
		_check_round_end()
	_broadcast()

func server_on_hit(victim_id: int, thrower_id: int) -> void:
	if not multiplayer.is_server() or state != State.PLAYING:
		return
	if not lives.has(victim_id) or lives[victim_id] <= 0:
		return
	if _team_of.get(victim_id, -1) == _team_of.get(thrower_id, -2):
		return
	lives[victim_id] -= 1
	if lives[victim_id] <= 0:
		_set_spectator(victim_id, true)
	_broadcast()
	_check_round_end()

func _start_round() -> void:
	if not _both_teams_present():
		state = State.WAITING
		status_text = ""
		_broadcast()
		return
	round_num += 1
	state = State.PLAYING
	status_text = "Round %d" % round_num
	for ball in get_tree().get_nodes_in_group("grabbable"):
		if ball.has_method("server_reset"):
			ball.server_reset()
	for id in _team_of:
		lives[id] = STARTING_LIVES
		_respawn(id)
	_broadcast()

func _check_round_end() -> void:
	if state != State.PLAYING:
		return
	var counts := _living_counts()
	var teams_alive := 0
	var winner := -1
	for t in range(TEAM_COUNT):
		if counts[t] > 0:
			teams_alive += 1
			winner = t
	if teams_alive <= 1:
		_end_round(winner)

func _end_round(winner: int) -> void:
	state = State.ROUND_OVER
	if winner >= 0:
		team_scores[winner] += 1
		status_text = "%s wins the round!" % TEAM_NAMES[winner]
	else:
		status_text = "Draw!"
	_broadcast()
	if winner >= 0 and team_scores[winner] >= WIN_SCORE:
		_end_match(winner)
	else:
		_schedule(_start_round, ROUND_RESET_DELAY)

func _end_match(winner: int) -> void:
	state = State.MATCH_OVER
	status_text = "%s wins the match!" % TEAM_NAMES[winner]
	_broadcast()
	_schedule(_reset_to_waiting, MATCH_RESET_DELAY)

func _reset_to_waiting() -> void:
	team_scores = [0, 0]
	round_num = 0
	state = State.WAITING
	status_text = ""
	_broadcast()

func _both_teams_present() -> bool:
	var counts := _team_player_counts()
	for t in range(TEAM_COUNT):
		if counts[t] < MIN_PER_TEAM:
			return false
	return true

func _team_player_counts() -> Array:
	var counts := [0, 0]
	for id in _team_of:
		var t: int = _team_of[id]
		if t >= 0 and t < TEAM_COUNT:
			counts[t] += 1
	return counts

func _living_counts() -> Array:
	var counts := [0, 0]
	for id in lives:
		if lives[id] > 0:
			var t: int = _team_of.get(id, -1)
			if t >= 0 and t < TEAM_COUNT:
				counts[t] += 1
	return counts

func _set_spectator(id: int, spectating: bool) -> void:
	var p := _player(id)
	if p:
		p.set_alive_remote.rpc(not spectating)

func _respawn(id: int) -> void:
	var p := _player(id)
	if p == null:
		return
	var spawner := get_tree().get_first_node_in_group("spawn_points")
	p.set_alive_remote.rpc(true)
	if spawner:
		var spawn: Dictionary = spawner.reserve(id)
		p.respawn_remote.rpc_id(id, spawn["position"], spawn["yaw"])

func _player(id: int) -> Node:
	return get_tree().current_scene.get_node_or_null(str(id))

func _schedule(cb: Callable, delay: float) -> void:
	_reset_token += 1
	var token := _reset_token
	await get_tree().create_timer(delay).timeout
	if token == _reset_token and multiplayer.is_server():
		cb.call()

func _broadcast() -> void:
	if not multiplayer.is_server():
		return
	_sync.rpc(state, team_scores, lives, _team_of, round_num, status_text)

@rpc("authority", "call_remote", "reliable")
func _sync(s: int, scores: Array, lv: Dictionary, teams: Dictionary, rnd: int, txt: String) -> void:
	state = s
	team_scores = scores
	lives = lv
	_team_of = teams
	round_num = rnd
	status_text = txt
