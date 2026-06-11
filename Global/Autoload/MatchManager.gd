extends Node

# Server-authoritative match flow. The host owns all state and pushes snapshots to
# clients via _sync; the HUD only reads them.

enum State { WAITING, PLAYING, ROUND_OVER, MATCH_OVER }

const STARTING_LIVES := 3
const WIN_SCORE := 5
const CTF_CAPTURE_LIMIT := 3
const TEAM_COUNT := 2
const MIN_PER_TEAM := 1
# Teams aren't decided in the lobby — players gather teamless and are split into teams only
# when a match starts (see _assign_teams). So starting just needs enough bodies present.
const MIN_PLAYERS := 2
const ROUND_RESET_DELAY := 3.0
const MATCH_RESET_DELAY := 6.0
const TEAM_NAMES := ["Red", "Blue"]

# Where each mode is played, and where everyone waits between matches. The starting pedestal
# picks the mode; this is the single source of truth mapping mode -> map. The persistent root
# (group "game_root") loads these on every peer.
const LOBBY_MAP := "res://Screens/Maps/LobbyMap.tscn"
# Both modes currently point at the Colosseum sandbox for testing; the original
# arenas are TeamArena.tscn and CTFArena.tscn.
const MAP_OF := {
	Pedestal.GameMode.TEAM: "res://Screens/Maps/ColosseumMap.tscn",
	Pedestal.GameMode.CAPTURE_THE_FLAG: "res://Screens/Maps/ColosseumMap.tscn",
}

var state: int = State.WAITING
var team_scores := [0, 0]
var lives := {}
var round_num := 0
var status_text := ""
# Which mode the active match is running. Values are Pedestal.GameMode; the starting
# pedestal picks it. Replicated so every peer (and the CTF arena) knows the mode.
var game_mode: int = Pedestal.GameMode.TEAM

# Server-authoritative match rules. Only the host reads these (it owns hit
# detection and scoring), so they don't need replicating. Defaults mirror
# real dodgeball: opponents' throws only.
var friendly_fire := false  # when true, a teammate's throw can get you out
var self_hit := false       # when true, your own thrown ball can get you out

var _team_of := {}
var _reset_token := 0

# A player joins teamless (team -1); _team_of doubles as the roster of present players.
# Their real team is assigned at match start.
func server_player_ready(id: int) -> void:
	if not multiplayer.is_server():
		return
	if not _team_of.has(id):
		_team_of[id] = -1
	if not lives.has(id):
		lives[id] = 0
	if state != State.WAITING:
		_set_spectator(id, true)
	_broadcast()

# Any player at the podium can ask the server to start; it validates and begins.
# mode is a Pedestal.GameMode, chosen by the pedestal that was used.
@rpc("any_peer", "reliable")
func request_start(mode: int = Pedestal.GameMode.TEAM) -> void:
	server_request_start(mode)

func server_request_start(mode: int = Pedestal.GameMode.TEAM) -> void:
	if not multiplayer.is_server() or not can_start():
		return
	game_mode = mode
	team_scores = [0, 0]
	round_num = 0
	# Split the teamless lobby roster into teams now, as the match begins.
	_assign_teams()
	# Swap every peer into this mode's map first, then wait a frame so the new map's
	# SpawnPoints and balls are in the tree before we reset and spawn players into them.
	await _load_map_for(MAP_OF[mode])
	# A player may have left during the swap; bail back to the lobby if we can't start anymore.
	if not _both_teams_present():
		await _to_lobby()
		state = State.WAITING
		status_text = ""
		_broadcast()
		return
	# The two modes are mutually exclusive: Team runs the rounds/elimination loop and is
	# won by round wins; CTF has no elimination and is won by flag captures.
	if game_mode == Pedestal.GameMode.CAPTURE_THE_FLAG:
		_start_ctf()
	else:
		_start_round()

func can_start() -> bool:
	return state == State.WAITING and _team_of.size() >= MIN_PLAYERS

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
	# CTF has no elimination — hits still shove players (that's physics), but cost no lives.
	if game_mode != Pedestal.GameMode.TEAM:
		return
	if not lives.has(victim_id) or lives[victim_id] <= 0:
		return
	if not can_hit(victim_id, thrower_id):
		return
	lives[victim_id] -= 1
	if lives[victim_id] <= 0:
		_set_spectator(victim_id, true)
	_broadcast()
	_check_round_end()

# Whether thrower_id's ball is allowed to get victim_id out. Central source of
# truth for the hit rules; the ball's detection and this scoring path both use it.
func can_hit(victim_id: int, thrower_id: int) -> bool:
	# Only a thrown ball is dangerous — bumping or jumping on a free ball is safe.
	if thrower_id == 0:
		return false
	if victim_id == thrower_id:
		return self_hit
	# The lobby (teamless WAITING) is a free-for-all so players can shove each other
	# around; matches use the configured friendly_fire rule (off = real dodgeball).
	var ff := friendly_fire or state == State.WAITING
	if not ff and _team_of.get(victim_id, -1) == _team_of.get(thrower_id, -2):
		return false
	return true

# Team index for a peer, or -1 if unknown.
func team_of(id: int) -> int:
	return _team_of.get(id, -1)

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

# CTF has a single continuous round: spawn everyone, reset objects, play until a team
# reaches CTF_CAPTURE_LIMIT captures. lives are set so players count as alive, but nothing
# decrements them (server_on_hit is a no-op here).
func _start_ctf() -> void:
	if not _both_teams_present():
		state = State.WAITING
		status_text = ""
		_broadcast()
		return
	state = State.PLAYING
	status_text = "Capture the Flag — first to %d" % CTF_CAPTURE_LIMIT
	for ball in get_tree().get_nodes_in_group("grabbable"):
		if ball.has_method("server_reset"):
			ball.server_reset()
	for id in _team_of:
		lives[id] = STARTING_LIVES
		_respawn(id)
	_broadcast()

# Reported by the CaptureTheFlag arena when a carrier delivers the flag. Owns CTF scoring
# so the HUD (which reads team_scores) shows it.
func server_on_flag_capture(scoring_team: int) -> void:
	if not multiplayer.is_server() or state != State.PLAYING:
		return
	if game_mode != Pedestal.GameMode.CAPTURE_THE_FLAG:
		return
	if scoring_team < 0 or scoring_team >= TEAM_COUNT:
		return
	team_scores[scoring_team] += 1
	if team_scores[scoring_team] >= CTF_CAPTURE_LIMIT:
		_end_match(scoring_team)
	else:
		status_text = "%s captured the flag!" % TEAM_NAMES[scoring_team]
		_broadcast()

func _check_round_end() -> void:
	# Last-team-standing only ends rounds in Team mode; CTF ends on captures.
	if game_mode != Pedestal.GameMode.TEAM:
		return
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
	await _to_lobby()
	_broadcast()

# Return to the lobby map and drop teams: everyone is teamless again until the next match.
func _to_lobby() -> void:
	await _load_map_for(LOBBY_MAP)
	_clear_teams()
	for id in _team_of:
		_respawn_neutral(id)

# Split the current roster into teams. This is the seam where player-chosen teams will plug
# in later; for now it auto-balances by a stable order (1st player Red, 2nd Blue, ...).
func _assign_teams() -> void:
	var ids := _team_of.keys()
	ids.sort()
	for i in range(ids.size()):
		_team_of[ids[i]] = i % TEAM_COUNT

func _clear_teams() -> void:
	for id in _team_of:
		_team_of[id] = -1

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
		# Keep the player's existing team so a fresh map's empty spawner can't flip it.
		var spawn: Dictionary = spawner.reserve(id, team_of(id))
		p.respawn_remote.rpc_id(id, spawn["position"], spawn["yaw"], spawn["team"])

# Lobby respawn: any free spot, no team (the player turns neutral).
func _respawn_neutral(id: int) -> void:
	var p := _player(id)
	if p == null:
		return
	var spawner := get_tree().get_first_node_in_group("spawn_points")
	p.set_alive_remote.rpc(true)
	if spawner:
		var spawn: Dictionary = spawner.reserve_any(id)
		p.respawn_remote.rpc_id(id, spawn["position"], spawn["yaw"], spawn["team"])

func _player(id: int) -> Node:
	return get_tree().current_scene.get_node_or_null(str(id))

func _game_root() -> Node:
	return get_tree().get_first_node_in_group("game_root")

# Swap every peer to `path` and wait a frame so the new map (and its SpawnPoints/balls) is in
# the tree before callers reset or respawn into it.
func _load_map_for(path: String) -> void:
	var root := _game_root()
	if root:
		root.load_map.rpc(path)
	await get_tree().process_frame

func _schedule(cb: Callable, delay: float) -> void:
	_reset_token += 1
	var token := _reset_token
	await get_tree().create_timer(delay).timeout
	if token == _reset_token and multiplayer.is_server():
		cb.call()

func _broadcast() -> void:
	if not multiplayer.is_server():
		return
	_sync.rpc(state, team_scores, lives, _team_of, round_num, status_text, game_mode)

@rpc("authority", "call_remote", "reliable")
func _sync(s: int, scores: Array, lv: Dictionary, teams: Dictionary, rnd: int, txt: String, mode: int) -> void:
	state = s
	team_scores = scores
	lives = lv
	_team_of = teams
	round_num = rnd
	status_text = txt
	game_mode = mode
