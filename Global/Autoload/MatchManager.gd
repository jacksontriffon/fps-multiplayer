extends Node

# Server-authoritative match flow. The host owns all state and pushes snapshots to
# clients via _sync; the HUD only reads them.

enum State { WAITING, PLAYING, ROUND_OVER, MATCH_OVER }

const STARTING_LIVES := 3
const WIN_SCORE := 5
const CTF_CAPTURE_LIMIT := 3
# CTF isn't elimination-based, so a knocked-out player isn't gone for good: they sit out
# briefly, then respawn at full hearts to keep the capture race going.
const CTF_RESPAWN_DELAY := 3.0
const TEAM_COUNT := 2
# Teams aren't decided in the lobby — players gather teamless and are split into teams only
# when a match starts (see _assign_teams). One player is enough to start so you can load into
# a map and test solo; with only one player present a round won't auto-end (see _is_contested).
const MIN_PLAYERS := 1
const ROUND_RESET_DELAY := 3.0
const MATCH_RESET_DELAY := 6.0
# How long the end-of-match screen lingers before the match auto-returns to the lobby (and
# everyone respawns there). Longer than MATCH_RESET_DELAY so players have time to read the
# result and choose Rematch; if nobody acts, the auto-return is the safety that un-sticks a
# match where everyone lost.
const END_SCREEN_LINGER := 15.0
const TEAM_NAMES := ["Red", "Blue"]

# Where each mode is played, and where everyone waits between matches. The starting pedestal
# picks the mode; this is the single source of truth mapping mode -> map. The persistent root
# (group "game_root") loads these on every peer.
const LOBBY_MAP := "res://Screens/Maps/LobbyMap.tscn"
# Every mode ships pointing at the Colosseum, the one template arena. Add your own maps under
# res://Screens/Maps and point modes at them here. Race needs a map with a RaceFinish trigger.
const DEFAULT_MAP := "res://Screens/Maps/ColosseumMap.tscn"
const MAP_OF := {
	Pedestal.GameMode.TEAM: DEFAULT_MAP,
	Pedestal.GameMode.CAPTURE_THE_FLAG: DEFAULT_MAP,
	Pedestal.GameMode.BATTLE_ROYALE: DEFAULT_MAP,
	Pedestal.GameMode.RACE: DEFAULT_MAP,
}
# Sandbox override for map testing: when true, a start with no chosen map falls back to
# SANDBOX_MAP. The Map Select menu always passes an explicit map, so it overrides this.
const SANDBOX_MAP := DEFAULT_MAP
const USE_SANDBOX_MAP := true

# The Map Select menu auto-discovers every .tscn in MAP_DIR (see map_choices), so a new map
# shows up just by being saved there — no list to maintain. EXCLUDE_MAPS hides non-arena scenes
# (file stem, no extension); NAME_OVERRIDES gives a curated label where the filename reads badly.
const MAP_DIR := "res://Screens/Maps/"
const EXCLUDE_MAPS := ["LobbyMap"]
const NAME_OVERRIDES := {
	"ColosseumMap": "Colosseum",
}

# Classic mode is a Team-Battle tournament: TOURNAMENT_MAPS maps drawn at random from this
# pool, played back to back. The team that wins the most maps wins the tournament.
# Add maps to this pool as you build them; with a single map the series is one map long.
const CLASSIC_MAP_POOL := [
	DEFAULT_MAP,
]
const TOURNAMENT_MAPS := 3

var state: int = State.WAITING
var team_scores := [0, 0]
var lives := {}
var round_num := 0
var status_text := ""
# Which mode the active match is running. Values are Pedestal.GameMode; the lobby menu picks
# it (Classic forces Team Battle). Replicated so every peer (and the CTF arena) knows the mode.
var game_mode: int = Pedestal.GameMode.TEAM

# Classic tournament progress. is_tournament marks a Classic run; the rest track which map of
# the series we're on and how many maps each team has banked. Replicated so the HUD can show
# the series score.
var is_tournament := false
var tournament_maps: Array = []
var tournament_index := 0
var tournament_wins := [0, 0]

# Server-authoritative match rules. Only the host reads these (it owns hit
# detection and scoring), so they don't need replicating. Defaults mirror
# real dodgeball: opponents' throws only.
var friendly_fire := false  # when true, a teammate's throw can get you out
var self_hit := false       # when true, your own thrown ball can get you out

var _team_of := {}
var _reset_token := 0

# The last match's setup, captured at start so Rematch (from the end screen) can replay it.
# Host-only; never replicated.
var _last_mode: int = Pedestal.GameMode.TEAM
var _last_map := ""
var _last_tournament := false

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

# Any player at the podium can ask the server to start; it validates and begins. mode is a
# Pedestal.GameMode and map_path the arena chosen in the Map Select menu (empty = use the
# mode's default / sandbox).
@rpc("any_peer", "reliable")
func request_start(mode: int = Pedestal.GameMode.TEAM, map_path: String = "") -> void:
	server_request_start(mode, map_path)

func server_request_start(mode: int = Pedestal.GameMode.TEAM, map_path: String = "") -> void:
	if not multiplayer.is_server() or not can_start():
		return
	is_tournament = false
	game_mode = mode
	team_scores = [0, 0]
	round_num = 0
	# Split the teamless lobby roster into teams now, as the match begins. Battle royale and
	# Race are every player for themselves, so the roster stays teamless (-1).
	if mode != Pedestal.GameMode.BATTLE_ROYALE and mode != Pedestal.GameMode.RACE:
		_assign_teams()
	# Swap every peer into the chosen map first, then wait a frame so the new map's
	# SpawnPoints and balls are in the tree before we reset and spawn players into them.
	# An explicit pick from Map Select wins; otherwise fall back to the sandbox/mode default.
	var chosen_map: String = map_path if map_path != "" else (SANDBOX_MAP if USE_SANDBOX_MAP else MAP_OF[mode])
	_last_mode = mode
	_last_map = chosen_map
	_last_tournament = false
	await _load_map_for(chosen_map)
	# A player may have left during the swap; bail back to the lobby if we can't start anymore.
	if not _enough_players_present():
		await _to_lobby()
		state = State.WAITING
		status_text = ""
		_broadcast()
		return
	# The modes are mutually exclusive: Team runs the rounds/elimination loop and is won by
	# round wins; CTF has no elimination and is won by flag captures; battle royale is a
	# single free-for-all round won by the last player standing.
	match game_mode:
		Pedestal.GameMode.CAPTURE_THE_FLAG:
			_start_ctf()
		Pedestal.GameMode.BATTLE_ROYALE:
			_start_battle_royale()
		Pedestal.GameMode.RACE:
			_start_race()
		_:
			_start_round()

# Classic tournament: a Team-Battle series across TOURNAMENT_MAPS random maps from the pool.
# Any player at the podium can kick it off; the server owns the flow.
@rpc("any_peer", "reliable")
func request_start_tournament() -> void:
	server_request_start_tournament()

func server_request_start_tournament() -> void:
	if not multiplayer.is_server() or not can_start():
		return
	var pool: Array = CLASSIC_MAP_POOL.duplicate()
	pool.shuffle()
	tournament_maps = pool.slice(0, TOURNAMENT_MAPS)
	tournament_index = 0
	tournament_wins = [0, 0]
	is_tournament = true
	game_mode = Pedestal.GameMode.TEAM
	team_scores = [0, 0]
	round_num = 0
	_last_tournament = true
	_assign_teams()
	await _load_map_for(tournament_maps[0])
	if not _enough_players_present():
		is_tournament = false
		await _to_lobby()
		state = State.WAITING
		status_text = ""
		_broadcast()
		return
	_start_round()

func can_start() -> bool:
	return state == State.WAITING and _team_of.size() >= MIN_PLAYERS

# Any player can abandon the current match from the pause menu; the host drops everyone back
# to the lobby. Returning to the lobby is inherently global — there's one shared map.
@rpc("any_peer", "reliable")
func request_to_lobby() -> void:
	server_request_to_lobby()

func server_request_to_lobby() -> void:
	if not multiplayer.is_server() or state == State.WAITING:
		return
	_reset_token += 1  # cancel any pending round/match transition before resetting
	_reset_to_waiting()

# Replay the last match (same mode + map, or a fresh tournament) straight from the end screen,
# skipping the trip back to the lobby. Only valid once a match is over; the pending auto-return
# is cancelled. If the roster has thinned out too much to restart, fall back to the lobby so the
# end screen never strands everyone on a finished arena.
@rpc("any_peer", "reliable")
func request_rematch() -> void:
	server_request_rematch()

func server_request_rematch() -> void:
	if not multiplayer.is_server() or state != State.MATCH_OVER:
		return
	_reset_token += 1  # cancel the pending auto-return to lobby
	state = State.WAITING  # satisfy can_start() for the restart below
	if not can_start():
		_reset_to_waiting()
		return
	if _last_tournament:
		server_request_start_tournament()
	else:
		server_request_start(_last_mode, _last_map)

# Peer ids of everyone present in the lobby, in a stable order. Read by the Map Select
# menu to list the players waiting before a match starts.
func roster() -> Array:
	var ids := _team_of.keys()
	ids.sort()
	return ids

# Selectable arenas for the Map Select menu: every .tscn under MAP_DIR (minus EXCLUDE_MAPS),
# sorted by label. Exported builds expose scenes as `.tscn.remap`, so both are folded to one
# stem and always referenced by their res:// .tscn path (the engine resolves the remap on load).
func map_choices() -> Array:
	var dir := DirAccess.open(MAP_DIR)
	if dir == null:
		return []
	var stems := {}
	for file in dir.get_files():
		var stem := ""
		if file.ends_with(".tscn"):
			stem = file.trim_suffix(".tscn")
		elif file.ends_with(".tscn.remap"):
			stem = file.trim_suffix(".tscn.remap")
		else:
			continue
		if stem in EXCLUDE_MAPS:
			continue
		stems[stem] = true
	var out: Array = []
	for stem in stems:
		out.append({"name": _map_display_name(stem), "path": MAP_DIR + stem + ".tscn"})
	out.sort_custom(func(a, b): return a["name"].naturalnocasecmp_to(b["name"]) < 0)
	return out

# Curated label if one exists, else the filename stem with spaces inserted at camelCase and
# letter/digit boundaries: "HungerGamesSandbox" -> "Hunger Games Sandbox", "Office2Player" -> "Office 2 Player".
func _map_display_name(stem: String) -> String:
	if NAME_OVERRIDES.has(stem):
		return NAME_OVERRIDES[stem]
	var out := ""
	for i in stem.length():
		var c := stem[i]
		if i > 0 and _new_word(stem[i - 1], c):
			out += " "
		out += c
	return out

func _new_word(prev: String, c: String) -> bool:
	var c_upper := c != c.to_lower() and c == c.to_upper()
	var c_digit := c >= "0" and c <= "9"
	var prev_upper := prev != prev.to_lower() and prev == prev.to_upper()
	var prev_digit := prev >= "0" and prev <= "9"
	if c_upper and not prev_upper and not prev_digit:
		return true
	return c_digit != prev_digit

func server_player_left(id: int) -> void:
	if not multiplayer.is_server():
		return
	_team_of.erase(id)
	lives.erase(id)
	if state == State.PLAYING:
		_check_round_end()
	_broadcast()

# Single per-victim outcome for a ball hit. The heart cost and the victim-side effect
# (death ragdoll, knockdown stun, or soft shove) ship together so they can't race.
# is_knockdown routes fast hits through the ragdoll; costs_life is the blast opt-out.
# Hearts are spent during any live match (team, CTF and battle royale); the lobby just
# shoves or stuns. A fatal hit ragdolls and eliminates in team/BR modes, while in CTF it
# only benches the player briefly before they respawn (see _ctf_knockout).
func server_resolve_hit(victim_id: int, thrower_id: int, impulse: Vector3, is_knockdown: bool, costs_life: bool = true, force := false) -> void:
	if not multiplayer.is_server():
		return
	if not force and not can_hit(victim_id, thrower_id):
		return
	var scoring := costs_life and state == State.PLAYING
	var fatal := false
	if scoring:
		if not lives.has(victim_id) or lives[victim_id] <= 0:
			return
		lives[victim_id] -= 1
		fatal = lives[victim_id] <= 0
	var p := _player(victim_id)
	if fatal:
		if game_mode == Pedestal.GameMode.CAPTURE_THE_FLAG:
			_ctf_knockout(victim_id)
		elif p:
			p.set_alive_remote.rpc(false, true)
			p.apply_knockdown.rpc_id(victim_id, impulse, 0.0, true)
	elif p:
		if is_knockdown:
			p.apply_knockdown.rpc_id(victim_id, impulse, Player.KNOCKDOWN_TIME, false)
		else:
			p.apply_knockback_remote.rpc_id(victim_id, impulse)
	if scoring:
		_broadcast()
		_check_round_end()

# A player fell into an out-of-bounds volume (see OutOfBounds). During a live match it costs one
# heart and respawns them at their spawn — a fatal fall eliminates them, mirroring a fatal hit
# (CTF benches and respawns instead). Outside a match (lobby/intermission) it just puts them back
# so they don't fall forever. Server-authoritative; the trigger only calls this on the host.
func server_player_fell(id: int) -> void:
	if not multiplayer.is_server() or _player(id) == null:
		return
	if state != State.PLAYING:
		# Outside a live match there are no hearts to spend. In the lobby, catch the fall and
		# respawn neutrally; during the brief intermission, leave them be (a reset is imminent).
		if state == State.WAITING:
			_respawn_neutral(id)
		return
	# Already eliminated and spectating — don't dock a heart or (crucially) revive them.
	if lives.get(id, 0) <= 0:
		return
	lives[id] -= 1
	_drop_held_items(id)
	if lives[id] <= 0:
		if game_mode == Pedestal.GameMode.CAPTURE_THE_FLAG:
			_ctf_knockout(id)
		else:
			var p := _player(id)
			if p:
				p.set_alive_remote.rpc(false, true)
	else:
		_respawn(id)
	_broadcast()
	_check_round_end()

# A +1 Heart orb pickup. The picker's own client calls this (rpc'd to the host), which adds
# a heart and broadcasts. There's no ceiling — players can stack hearts past the round-start
# count (each one also reserves a slice of the stamina pool, so it's a survivability/stamina
# trade). Only meaningful during a live match and never revives an eliminated player (0 hearts)
# — that's an elimination, not a wound.
@rpc("any_peer", "reliable")
func request_add_heart() -> void:
	server_add_heart(multiplayer.get_remote_sender_id())

func server_add_heart(id: int) -> void:
	if not multiplayer.is_server() or state != State.PLAYING:
		return
	if lives.get(id, 0) <= 0:
		return
	lives[id] += 1
	_broadcast()

# Whether thrower_id's ball is allowed to get victim_id out. Central source of
# truth for the hit rules; the ball's detection and this scoring path both use it.
func can_hit(victim_id: int, thrower_id: int) -> bool:
	# Only a thrown ball is dangerous — bumping or jumping on a free ball is safe.
	if thrower_id == 0:
		return false
	if victim_id == thrower_id:
		return self_hit
	# The lobby (teamless WAITING), battle royale and race are free-for-alls; team matches use
	# the configured friendly_fire rule (off = real dodgeball).
	var ff := friendly_fire or state == State.WAITING \
		or game_mode == Pedestal.GameMode.BATTLE_ROYALE \
		or game_mode == Pedestal.GameMode.RACE
	if not ff and _team_of.get(victim_id, -1) == _team_of.get(thrower_id, -2):
		return false
	return true

# Team index for a peer, or -1 if unknown.
func team_of(id: int) -> int:
	return _team_of.get(id, -1)

# Whether `mode` is the gamemode currently being played. False in the lobby (WAITING), where
# no mode is active. Replicated state, so every peer agrees — gamemode-specific map objects
# (CTF flags, bases) gate their visibility on this so they only show in their own mode.
func is_mode_active(mode: int) -> bool:
	return state != State.WAITING and game_mode == mode

func _start_round() -> void:
	if not _enough_players_present():
		state = State.WAITING
		status_text = ""
		_broadcast()
		return
	round_num += 1
	state = State.PLAYING
	status_text = _round_status()
	_reset_round_abilities()
	for ball in get_tree().get_nodes_in_group("grabbable"):
		if ball.has_method("server_reset"):
			ball.server_reset()
	for id in _team_of:
		lives[id] = STARTING_LIVES
		_respawn(id)
	_broadcast()

# CTF has a single continuous round: spawn everyone, reset objects, play until a team
# reaches CTF_CAPTURE_LIMIT captures. Hits cost hearts like any mode, but a knockout here
# only benches the player for CTF_RESPAWN_DELAY before they respawn (see _ctf_knockout).
func _start_ctf() -> void:
	if not _enough_players_present():
		state = State.WAITING
		status_text = ""
		_broadcast()
		return
	state = State.PLAYING
	status_text = "Capture the Flag — first to %d" % CTF_CAPTURE_LIMIT
	_reset_round_abilities()
	for ball in get_tree().get_nodes_in_group("grabbable"):
		if ball.has_method("server_reset"):
			ball.server_reset()
	for id in _team_of:
		lives[id] = STARTING_LIVES
		_respawn(id)
	_broadcast()

# Battle royale: one continuous free-for-all round, last player with lives left wins.
func _start_battle_royale() -> void:
	state = State.PLAYING
	status_text = "Battle Royale — last one standing"
	_reset_round_abilities()
	for ball in get_tree().get_nodes_in_group("grabbable"):
		if ball.has_method("server_reset"):
			ball.server_reset()
	for id in _team_of:
		lives[id] = STARTING_LIVES
		_respawn(id)
	_broadcast()

# Race: one continuous free-for-all from the start line to the finish. First racer to reach the
# finish wins (server_on_race_finish); hearts still matter — a ball hit or a fall (out of bounds)
# costs one and respawns you at the start, and running out eliminates you from the race.
func _start_race() -> void:
	state = State.PLAYING
	status_text = "Race — first to the finish!"
	_reset_round_abilities()
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
	if state != State.PLAYING:
		return
	# Solo testing: with only one player there's no opponent to eliminate, so don't auto-end the
	# round/match — let them roam the arena until someone joins or they leave.
	if not _is_contested():
		return
	# Battle royale ends when one player is left; CTF ends on captures, not eliminations.
	if game_mode == Pedestal.GameMode.BATTLE_ROYALE:
		_check_br_end()
		return
	# Race ends when someone reaches the finish (see server_on_race_finish); eliminations only
	# decide it if everyone but one racer is knocked out first.
	if game_mode == Pedestal.GameMode.RACE:
		_check_race_end()
		return
	if game_mode != Pedestal.GameMode.TEAM:
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
		if is_tournament:
			_win_tournament_map(winner)
		else:
			_end_match(winner)
	else:
		_schedule(_start_round, ROUND_RESET_DELAY)

# A team reached WIN_SCORE on the current tournament map: bank the map win, then either
# advance to the next map or, once a team has clinched the series (or all maps are played),
# crown the champion.
func _win_tournament_map(winner: int) -> void:
	tournament_wins[winner] += 1
	var clinched: bool = tournament_wins[winner] > tournament_maps.size() / 2
	var last_map: bool = tournament_index >= tournament_maps.size() - 1
	if clinched or last_map:
		_end_tournament()
		return
	status_text = "%s takes the map!  Series %d–%d" % [TEAM_NAMES[winner], tournament_wins[0], tournament_wins[1]]
	_broadcast()
	_schedule(_next_tournament_map, MATCH_RESET_DELAY)

# Load the next map in the series (teams carry over) and start a fresh first-to-WIN_SCORE match.
func _next_tournament_map() -> void:
	tournament_index += 1
	team_scores = [0, 0]
	round_num = 0
	await _load_map_for(tournament_maps[tournament_index])
	if not _enough_players_present():
		_end_tournament()
		return
	_start_round()

func _end_tournament() -> void:
	state = State.MATCH_OVER
	var champ := -1
	if tournament_wins[0] > tournament_wins[1]:
		champ = 0
	elif tournament_wins[1] > tournament_wins[0]:
		champ = 1
	if champ >= 0:
		status_text = "%s wins the tournament!  (%d–%d)" % [TEAM_NAMES[champ], tournament_wins[0], tournament_wins[1]]
	else:
		status_text = "Tournament drawn!  (%d–%d)" % [tournament_wins[0], tournament_wins[1]]
	is_tournament = false
	_broadcast()
	_schedule(_reset_to_waiting, END_SCREEN_LINGER)

# Round banner: in a tournament it carries the map number so players know where they are.
func _round_status() -> String:
	if is_tournament:
		return "Map %d/%d · Round %d" % [tournament_index + 1, tournament_maps.size(), round_num]
	return "Round %d" % round_num

func _end_match(winner: int) -> void:
	state = State.MATCH_OVER
	status_text = "%s wins the match!" % TEAM_NAMES[winner]
	_broadcast()
	_schedule(_reset_to_waiting, END_SCREEN_LINGER)

func _check_br_end() -> void:
	var winner := -1
	var alive_n := 0
	for id in _team_of:
		if lives.get(id, 0) > 0:
			alive_n += 1
			winner = id
	if alive_n <= 1:
		_end_match_br(winner if alive_n == 1 else -1)

func _end_match_br(winner_id: int) -> void:
	state = State.MATCH_OVER
	status_text = ("Player %d is the last one standing!" % winner_id) if winner_id > 0 else "Nobody survived!"
	_broadcast()
	_schedule(_reset_to_waiting, END_SCREEN_LINGER)

# Reported by a RaceFinish trigger when a racer crosses the line. The first valid crosser wins;
# once the match is over (state left PLAYING) later crossers are ignored.
func server_on_race_finish(id: int) -> void:
	if not multiplayer.is_server() or state != State.PLAYING:
		return
	if game_mode != Pedestal.GameMode.RACE or lives.get(id, 0) <= 0:
		return
	_end_match_race(id)

# Race fallback: if everyone but one racer is eliminated before anyone finishes, the survivor
# wins. Mirrors the battle-royale last-standing check.
func _check_race_end() -> void:
	var winner := -1
	var alive_n := 0
	for id in _team_of:
		if lives.get(id, 0) > 0:
			alive_n += 1
			winner = id
	if alive_n <= 1:
		_end_match_race(winner if alive_n == 1 else -1)

func _end_match_race(winner_id: int) -> void:
	state = State.MATCH_OVER
	status_text = ("Player %d wins the race!" % winner_id) if winner_id > 0 else "Nobody finished the race!"
	_broadcast()
	_schedule(_reset_to_waiting, END_SCREEN_LINGER)

func _reset_to_waiting() -> void:
	team_scores = [0, 0]
	round_num = 0
	is_tournament = false
	tournament_wins = [0, 0]
	tournament_index = 0
	tournament_maps = []
	state = State.WAITING
	status_text = ""
	await _to_lobby()
	_broadcast()

# Wipe all match state for a clean re-host (transport switch, see game.gd switch_net_mode).
# No peer exists at this point, so this just clears local state; the fresh session repopulates
# the roster as players register via server_player_ready.
func reset_for_rehost() -> void:
	state = State.WAITING
	team_scores = [0, 0]
	lives = {}
	round_num = 0
	status_text = ""
	game_mode = Pedestal.GameMode.TEAM
	is_tournament = false
	tournament_maps = []
	tournament_index = 0
	tournament_wins = [0, 0]
	_team_of = {}
	_reset_token += 1

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

# Enough bodies to start/keep a match: a single player is allowed (solo testing). Teams are
# auto-split on start, so 2+ players always means both sides are filled.
func _enough_players_present() -> bool:
	return _team_of.size() >= MIN_PLAYERS

# Whether a match can be decided by play: needs a real opponent. Below this, elimination and
# last-standing checks are skipped so a solo player isn't instantly declared the winner.
func _is_contested() -> bool:
	return _team_of.size() >= 2

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
		p.set_alive_remote.rpc(not spectating, false)

# CTF knockout: bench the player and free anything they held (a downed carrier must drop
# the flag, not keep it glued to an invisible body), then queue their respawn.
func _ctf_knockout(victim_id: int) -> void:
	_set_spectator(victim_id, true)
	_drop_held_items(victim_id)
	_ctf_respawn_after(victim_id)

func _ctf_respawn_after(victim_id: int) -> void:
	await get_tree().create_timer(CTF_RESPAWN_DELAY).timeout
	# The match may have ended or the player left while they were benched; only respawn if
	# CTF is still being played and they're still on the roster.
	if not multiplayer.is_server() or state != State.PLAYING:
		return
	if game_mode != Pedestal.GameMode.CAPTURE_THE_FLAG or not lives.has(victim_id):
		return
	lives[victim_id] = STARTING_LIVES
	_respawn(victim_id)
	_broadcast()

# Release every grabbable a player is carrying (the server owns ball authority, so it can
# release directly; the held_by sync drops the ball on every peer).
func _drop_held_items(id: int) -> void:
	for g in get_tree().get_nodes_in_group("grabbable"):
		if g.held_by == id and g.has_method("release"):
			g.release()

func _respawn(id: int) -> void:
	var p := _player(id)
	if p == null:
		return
	var spawner := spawner_for(game_mode)
	p.set_alive_remote.rpc(true, false)
	if spawner:
		# Battle royale and race are free-for-alls, so drop the player onto a random spawn point;
		# team and CTF keep them on their own team's spawns (handled below).
		if game_mode == Pedestal.GameMode.BATTLE_ROYALE or game_mode == Pedestal.GameMode.RACE:
			var spawn: Dictionary = spawner.reserve_any(id)
			p.respawn_remote.rpc_id(id, spawn["position"], spawn["yaw"], spawn["team"])
			return
		# Keep the player's existing team so a fresh map's empty spawner can't flip it.
		var spawn: Dictionary = spawner.reserve(id, team_of(id))
		p.respawn_remote.rpc_id(id, spawn["position"], spawn["yaw"], spawn["team"])

# Lobby respawn: any free spot, no team (the player turns neutral).
func _respawn_neutral(id: int) -> void:
	var p := _player(id)
	if p == null:
		return
	var spawner := spawner_for(-1)
	p.set_alive_remote.rpc(true, false)
	if spawner:
		var spawn: Dictionary = spawner.reserve_any(id)
		p.respawn_remote.rpc_id(id, spawn["position"], spawn["yaw"], spawn["team"])

# The spawn manager to use right now: the active mode's set during a match, the
# mode-agnostic set while waiting in the lobby.
func current_spawner() -> SpawnPoints:
	return spawner_for(game_mode if state != State.WAITING else -1)

# The spawn manager serving `mode` in the current map. Prefers an exact mode match, then a
# mode-agnostic manager (-1, e.g. the lobby or single-set maps), then whatever exists.
func spawner_for(mode: int) -> SpawnPoints:
	var any: SpawnPoints = null
	var agnostic: SpawnPoints = null
	for s in get_tree().get_nodes_in_group("spawn_points"):
		if s is not SpawnPoints:
			continue
		if s.mode == mode:
			return s
		if s.mode == -1 and agnostic == null:
			agnostic = s
		if any == null:
			any = s
	return agnostic if agnostic else any

func _player(id: int) -> Node:
	return get_tree().current_scene.get_node_or_null(str(id))

func _game_root() -> Node:
	return get_tree().get_first_node_in_group("game_root")

# Swap every peer to `path` and wait a frame so the new map (and its SpawnPoints/balls) is in
# the tree before callers reset or respawn into it. Players persist across the swap, so wipe
# their granted upgrades here — every map change, rematch and lobby return drops everyone back
# to the orb-less default state (the new map's orbs must be re-collected).
func _load_map_for(path: String) -> void:
	var root := _game_root()
	if root:
		root.load_map.rpc(path, randi())  # fresh per-instance seed; server-authoritative, sent to all peers
	for p in get_tree().get_nodes_in_group("players"):
		p.reset_upgrades.rpc()
	await get_tree().process_frame

# Start-of-round reset of collectable upgrades, driven by the active game mode. The default
# policy (every mode for now) wipes each player's abilities and respawns every ability orb, so a
# round begins orb-less and the abilities must be re-collected. Constant (time_limit 0) grants are
# what this clears — timed orbs already self-expire. Modes with a single continuous round (CTF,
# battle royale, race) call this once at their start, so their abilities last the whole round.
# Broadcast per node (like _load_map_for's reset_upgrades) so every peer's copy agrees.
func _reset_round_abilities() -> void:
	for p in get_tree().get_nodes_in_group("players"):
		p.reset_upgrades.rpc()
	for orb in get_tree().get_nodes_in_group("ability_orbs"):
		orb.round_respawn.rpc()

func _schedule(cb: Callable, delay: float) -> void:
	_reset_token += 1
	var token := _reset_token
	await get_tree().create_timer(delay).timeout
	if token == _reset_token and multiplayer.is_server():
		cb.call()

func _broadcast() -> void:
	if not multiplayer.is_server():
		return
	_sync.rpc(state, team_scores, lives, _team_of, round_num, status_text, game_mode, is_tournament, tournament_wins)

@rpc("authority", "call_remote", "reliable")
func _sync(s: int, scores: Array, lv: Dictionary, teams: Dictionary, rnd: int, txt: String, mode: int, tourney: bool, twins: Array) -> void:
	state = s
	team_scores = scores
	lives = lv
	_team_of = teams
	round_num = rnd
	status_text = txt
	game_mode = mode
	is_tournament = tourney
	tournament_wins = twins
