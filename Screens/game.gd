extends Node3D

# Persistent game root. Owns networking, the player nodes (spawned by the MultiplayerSpawner
# as direct children of this node) and a single swappable MapContainer child. This node stays
# `current_scene` for the whole session, so every `current_scene.get_node(str(id))` player
# lookup keeps working as maps come and go underneath it.
#
# Maps are deterministic scene files: the host RPCs load_map() and every peer instances the
# SAME scene at MapContainer/Map, so the path-based MultiplayerSynchronizers inside (balls,
# flags) line up across peers. The lobby is just one of those maps — it is never played in.

enum NetMode { STEAM, LOCAL }

const LOBBY_MAP := "res://Screens/Maps/LobbyMap.tscn"

## Defaults to STEAM. Set to LOCAL in the inspector to test two windows on one machine over
## ENet loopback, bypassing Steam entirely. Leave as STEAM for real builds.
@export var net_mode: NetMode = NetMode.STEAM
@export var local_address: String = "127.0.0.1"
@export var local_port: int = 7777
@export var player_scene: PackedScene
## Dev-only: unlocks creative map-building mode (F2 / pause-menu toggle). Off by default so
## creative is never reachable in normal play; flip it on while building maps.
@export var dev_mode: bool = false

var lobby_id: int = 0
# Per-instance random seed for deterministic-but-varied map content (e.g. RANDOM ability orbs).
# The server mints a fresh one for every load_map and ships it to all peers through that RPC, so
# each map instance rolls the same on every peer yet differs each time it loads. Seeded here too
# (randi() is auto-seeded per launch) for the authored lobby map, which never goes through load_map.
var match_seed: int = randi()
var peer: MultiplayerPeer
var is_host: bool = false
var is_joining: bool = false
# Set while we intentionally close our own peer (leave / re-host) so the server_disconnected
# handler doesn't mistake it for the host dropping us and trigger a recovery re-host.
var _tearing_down: bool = false
# Steam is initialised lazily so a session that boots in LOCAL can still switch to STEAM later.
var _steam_ready: bool = false
# Reason the last Steam init failed (Steamworks' verbal), kept so the lobby menu can explain why
# we dropped to LOCAL. Empty once Steam comes up.
var last_steam_error: String = ""
# The map currently loaded under MapContainer. On the server this is the source of truth a
# late-joiner pulls so it loads the live arena instead of the lobby.
var current_map_path: String = LOBBY_MAP

@onready var map_container: Node3D = $MapContainer


func _ready() -> void:
	add_to_group("game_root")
	# Keep our "in a party" presence current as players join/leave, on host and client alike.
	multiplayer.peer_connected.connect(_on_peer_count_changed)
	multiplayer.peer_disconnected.connect(_on_peer_count_changed)
	# Recover instead of freezing if a join never connects or the host drops us.
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	# The lobby map is authored under MapContainer for an editor preview; only instance it at
	# runtime as a fallback if it isn't already there (no peer yet, so call load_map directly,
	# not via .rpc()). Every peer boots into the lobby; a mid-match joiner pulls the live map.
	if map_container.get_child_count() == 0:
		load_map(LOBBY_MAP)

	# No menu screen: boot straight into a hosted solo lobby so the player spawns into the lobby
	# and uses the pedestal to start matches or join friends. Networking is what spawns the local
	# player (_start_host -> _add_player), so we host on boot rather than waiting on a button.
	_auto_host()

# Bring up the boot session. Prefer Steam so friends can see and join the lobby; if Steam isn't
# available, fall back to a local ENet session so the player can still play solo.
func _auto_host() -> void:
	if net_mode == NetMode.STEAM and _ensure_steam_init():
		host_lobby()
		return
	net_mode = NetMode.LOCAL
	print("Network mode: LOCAL (ENet %s:%d)" % [local_address, local_port])
	# Two-window local testing: the first instance hosts; a second instance finds the port already
	# taken and joins it instead, so both windows spawn into the shared lobby with no menu.
	is_host = true
	if _host_enet() != "":
		is_host = false
		_join_enet()

# Initialise Steam once, wiring the lobby callbacks a single time. Returns false on failure so
# callers can fall back. Safe to call repeatedly.
func _ensure_steam_init() -> bool:
	if _steam_ready:
		return true
	var init := Steam.steamInitEx(4847730, true)
	print("Steam init: ", init)
	if init["status"] != Steam.STEAM_API_INIT_RESULT_OK:
		push_error("Steam init failed (%d): %s" % [init["status"], init["verbal"]])
		last_steam_error = init["verbal"]
		_log_steam_diagnostics()
		return false
	last_steam_error = ""
	print("Steam ready: user %d, subscribed to app %d = %s" % [Steam.getSteamID(), Steam.getAppID(), Steam.isSubscribedApp(4847730)])
	Steam.initRelayNetworkAccess()
	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)
	# Accepting a friend's invite or "Join Game" from the Steam overlay routes here.
	Steam.join_requested.connect(_on_join_requested)
	_steam_ready = true
	return true

# Dump the surrounding state when init fails so a player's log tells us *why*. The key signal is
# isSteamRunning: false means our process can't reach the Steam client at all (Steam closed, a
# different Windows user, or an elevation mismatch — game run as admin while Steam isn't, or vice
# versa); true means Steam is reachable but rejected this app (the logged-in account has no license
# for this app_id). The env vars show which appid/Steam install the SDK resolved.
func _log_steam_diagnostics() -> void:
	print("--- Steam diagnostics ---")
	print("  isSteamRunning: ", Steam.isSteamRunning())
	print("  resolved AppID: ", Steam.getAppID())
	print("  SteamAppId env: '%s'  SteamGameId env: '%s'" % [OS.get_environment("SteamAppId"), OS.get_environment("SteamGameId")])
	print("  SteamPath env: '%s'" % OS.get_environment("SteamPath"))
	print("  SteamClientLaunch env: '%s'" % OS.get_environment("SteamClientLaunch"))
	print("  executable: ", OS.get_executable_path())
	print("-------------------------")

# --- Runtime transport switch ----------------------------------------------

# Re-host in a different transport without restarting the app. Host-only and destructive: the
# current session is torn down (any connected clients drop) and a fresh lobby is hosted in the
# chosen mode. Driven by the lobby pedestal menu — typically the host flipping Local <-> Steam
# while testing. Returns "" on success or a player-facing error the menu can surface; on a
# pre-host failure (e.g. Steam unavailable) the current session is left untouched.
func switch_net_mode(mode: NetMode) -> String:
	if not multiplayer.is_server():
		return "Only the host can change the network mode."
	if mode == net_mode and multiplayer.has_multiplayer_peer():
		return ""
	if mode == NetMode.STEAM and not _ensure_steam_init():
		return "Steam isn't available. Is the Steam client running?"
	_teardown_session()
	net_mode = mode
	return host_lobby()

# Drop every spawned player, reset match state and close the peer, leaving a bare lobby ready
# to be re-hosted.
func _teardown_session() -> void:
	_tearing_down = true
	for child in get_children():
		if str(child.name).is_valid_int():  # player nodes are named by peer id
			child.free()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	is_host = false
	lobby_id = 0
	current_map_path = LOBBY_MAP
	MatchManager.reset_for_rehost()
	load_map(LOBBY_MAP, randi())
	_tearing_down = false


# --- Map swapping ----------------------------------------------------------

# Swap MapContainer's single child to `path`. call_local so the host loads too; every peer
# instances the same scene named "Map" → identical node paths for the synchronizers inside.
@rpc("authority", "call_local", "reliable")
func load_map(path: String, p_match_seed: int = match_seed) -> void:
	current_map_path = path
	match_seed = p_match_seed  # adopt this load's seed before the map (and its orbs) instance
	for c in map_container.get_children():
		c.free()  # immediate, not queue_free: never let two maps coexist for a frame
	# A player map saved to user:// only exists on the host's machine, so a client can be asked
	# to load a path it doesn't have — bail instead of crashing on a null scene.
	var packed := load(path) as PackedScene
	if packed == null:
		push_error("Map not available on this peer: %s" % path)
		return
	var inst := packed.instantiate()
	inst.name = "Map"
	map_container.add_child(inst)
	# Re-apply any saved creative edits for this map (host broadcasts them; a no-peer boot
	# applies directly).
	CreativeManager.notify_map_loaded(path)
	# Tell friends which map we're on now (and whether we're back in the joinable lobby).
	_update_rich_presence()

# Pull model for late joiners: a client asks once it is connected, the server replies with the
# live map. Avoids a client receiving load_map before its MapContainer exists.
@rpc("any_peer", "reliable")
func request_current_map() -> void:
	if not multiplayer.is_server():
		return
	var joiner := multiplayer.get_remote_sender_id()
	load_map.rpc_id(joiner, current_map_path, match_seed)
	# The joiner just loaded the bare map; catch them up to the current creative layout.
	CreativeManager.send_overrides_to(joiner, current_map_path)

func _on_connected_to_server() -> void:
	request_current_map.rpc_id(1)


# --- Steam presence --------------------------------------------------------

# Publish the map we're on so friends' lobby list can show it, plus whether we're in the joinable
# lobby (friends can only join from there). Steam-only and safe to call before Steam is up.
func _update_rich_presence() -> void:
	if net_mode != NetMode.STEAM or not _steam_ready:
		return
	Steam.setRichPresence("map", _map_display_name(current_map_path))
	Steam.setRichPresence("in_lobby", "1" if current_map_path == LOBBY_MAP else "0")
	# "In a party" = sharing the session with at least one other player.
	var party := multiplayer.has_multiplayer_peer() and multiplayer.get_peers().size() >= 1
	Steam.setRichPresence("party", "1" if party else "0")

func _on_peer_count_changed(_id: int) -> void:
	_update_rich_presence()

# A join attempt never connected (host gone, relay failure). Don't strand the player on a dead
# peer — drop it and re-host our own lobby so they're back in a working session.
func _on_connection_failed() -> void:
	push_error("Connection to host failed; re-hosting.")
	multiplayer.multiplayer_peer = null
	is_joining = false
	_auto_host()

# The host dropped us mid-session (closed lobby, crash). Return to a fresh lobby of our own rather
# than freezing on a dead session. Ignored when we closed the peer ourselves (leave / re-host).
func _on_server_disconnected() -> void:
	if _tearing_down:
		return
	push_error("Host disconnected; returning to a fresh lobby.")
	_teardown_session()
	_auto_host()

# Invite a friend to the Steam lobby we're currently in (host or client). They get the usual Steam
# invite, and accepting routes through _on_join_requested. No-op outside a Steam lobby.
func invite_to_lobby(friend_steam_id: int) -> void:
	if net_mode != NetMode.STEAM or lobby_id == 0:
		return
	Steam.inviteUserToLobby(lobby_id, friend_steam_id)

# Human-readable map label for presence/UI: the lobby reads "Lobby", everything else uses the
# curated name MatchManager already keeps, falling back to the file stem.
func _map_display_name(path: String) -> String:
	if path == LOBBY_MAP:
		return "Lobby"
	var stem := path.get_file().get_basename()
	return MatchManager.NAME_OVERRIDES.get(stem, stem)


# --- Hosting ---------------------------------------------------------------

# Returns "" on success or a player-facing error. Steam hosting is async (the lobby arrives via
# _on_lobby_created), so it can only report the synchronous failures here; ENet reports inline.
func host_lobby() -> String:
	is_host = true
	if net_mode == NetMode.STEAM:
		# Friends-only: only the host's Steam friends see and join the lobby.
		Steam.createLobby(Steam.LobbyType.LOBBY_TYPE_FRIENDS_ONLY, 16)
		return ""
	return _host_enet()

func _on_lobby_created(result: int, new_lobby_id: int):
	# Lobby creation failed (Steam down, not logged in, etc.). Don't leave the player in a dead
	# session with no body — fall back to a local host so they at least spawn into the lobby solo.
	if result != Steam.Result.RESULT_OK:
		push_error("Steam lobby creation failed (%d); falling back to local host." % result)
		net_mode = NetMode.LOCAL
		is_host = true
		if _host_enet() != "":
			is_host = false
		return

	lobby_id = new_lobby_id
	# Make the lobby discoverable/joinable so friends' presence resolves a lobby to join into.
	Steam.setLobbyJoinable(lobby_id, true)
	Steam.setLobbyData(lobby_id, "name", "%s's lobby" % Steam.getPersonaName())

	var steam_peer := SteamMultiplayerPeer.new()
	steam_peer.server_relay = true
	steam_peer.create_host()
	_start_host(steam_peer)

	print("Lobby created: ID #", lobby_id)

func _host_enet() -> String:
	var enet_peer := ENetMultiplayerPeer.new()
	var err := enet_peer.create_server(local_port)
	if err != OK:
		push_error("Failed to create ENet server on port %d (error %d)" % [local_port, err])
		return "Couldn't host locally. Port %d may be in use (error %d)." % [local_port, err]
	_start_host(enet_peer)
	print("ENet server listening on port ", local_port)
	return ""

# Shared host setup for either transport.
func _start_host(new_peer: MultiplayerPeer):
	peer = new_peer
	multiplayer.multiplayer_peer = peer
	if not multiplayer.peer_connected.is_connected(_add_player):
		multiplayer.peer_connected.connect(_add_player)
	if not multiplayer.peer_disconnected.is_connected(_remove_player):
		multiplayer.peer_disconnected.connect(_remove_player)
	_add_player()
	# The lobby map loaded before Steam was up at boot, so publish our presence now we're hosting.
	_update_rich_presence()


# --- Joining ---------------------------------------------------------------

# Leave the session we're in (typically our own hosted solo lobby) and join a friend's instead.
# Driven by the lobby menu's friend list and by the Steam overlay's "Join Game". Joining is always
# over Steam, so a player hosting LOCAL is switched to Steam first.
func leave_and_join_lobby(target_lobby_id: int) -> void:
	if target_lobby_id == 0 or target_lobby_id == lobby_id:
		return
	var prev_lobby := lobby_id
	if multiplayer.has_multiplayer_peer():
		_teardown_session()
	if net_mode == NetMode.STEAM and prev_lobby != 0:
		Steam.leaveLobby(prev_lobby)
	if net_mode != NetMode.STEAM:
		net_mode = NetMode.STEAM
		if not _ensure_steam_init():
			return
	join_lobby(target_lobby_id)

func _on_join_requested(target_lobby_id: int, _friend_id: int) -> void:
	leave_and_join_lobby(target_lobby_id)

func join_lobby(target_lobby_id: int):
	is_joining = true
	Steam.joinLobby(target_lobby_id)

func _on_lobby_joined(joined_lobby_id: int, _permissions: int, _locked: bool, response: int):
	if !is_joining:
		return
	is_joining = false

	# Join failed (lobby full, gone, banned, …). We've usually already left our own lobby to get
	# here, so re-host a fresh one instead of leaving the player stranded with no session.
	if response != Steam.CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
		push_error("Failed to join lobby %d (response %d); re-hosting." % [joined_lobby_id, response])
		host_lobby()
		return

	lobby_id = joined_lobby_id
	var steam_peer := SteamMultiplayerPeer.new()
	steam_peer.server_relay = true
	steam_peer.create_client(Steam.getLobbyOwner(joined_lobby_id))
	peer = steam_peer
	multiplayer.multiplayer_peer = peer
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)

func _join_enet():
	var enet_peer := ENetMultiplayerPeer.new()
	var err := enet_peer.create_client(local_address, local_port)
	if err != OK:
		push_error("Failed to connect to %s:%d (error %d)" % [local_address, local_port, err])
		return
	peer = enet_peer
	multiplayer.multiplayer_peer = peer
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)


# --- Player spawn / despawn ---------------------------

func _add_player(id: int = 1):
	var player = player_scene.instantiate()
	player.name = str(id)
	var spawner := MatchManager.current_spawner()
	if spawner:
		# Lobby spawn: any free spot, teamless (player.team -1 reads as neutral grey).
		var spawn: Dictionary = spawner.reserve_any(id)
		player.team = spawn["team"]
		player.position = spawn["position"]
		player.get_node("Head").rotation.y = spawn["yaw"]
	call_deferred("add_child", player)

func _remove_player(id: int):
	# Maps can hold one spawn manager per mode; drop the player's slot from all of them.
	for spawner in get_tree().get_nodes_in_group("spawn_points"):
		spawner.release(id)
	MatchManager.server_player_left(id)

	if !self.has_node(str(id)):
		print("Removing player id that is not in Game")
		return

	self.get_node(str(id)).queue_free()


