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
# Steam is initialised lazily so a session that boots in LOCAL can still switch to STEAM later.
var _steam_ready: bool = false
# The map currently loaded under MapContainer. On the server this is the source of truth a
# late-joiner pulls so it loads the live arena instead of the lobby.
var current_map_path: String = LOBBY_MAP

@onready var map_container: Node3D = $MapContainer
@onready var host_game_button: Button = $UILayer/CenterContainer/VBoxContainer/VBoxContainer/HostGameButton
@onready var join_game_button: Button = $UILayer/CenterContainer/VBoxContainer/VBoxContainer/JoinGameButton
@onready var line_edit: LineEdit = $UILayer/CenterContainer/VBoxContainer/VBoxContainer/LineEdit


func _ready() -> void:
	add_to_group("game_root")
	# The lobby map is authored under MapContainer for an editor preview; only instance it at
	# runtime as a fallback if it isn't already there (no peer yet, so call load_map directly,
	# not via .rpc()). Every peer boots into the lobby; a mid-match joiner pulls the live map.
	if map_container.get_child_count() == 0:
		load_map(LOBBY_MAP)

	_apply_net_mode_ui()
	host_game_button.grab_focus()

# Bring the chosen transport online and refresh the start menu's Host/Join buttons. STEAM needs
# a successful init; LOCAL is always ready. Called on boot and after a runtime mode switch.
func _apply_net_mode_ui() -> void:
	if net_mode == NetMode.STEAM:
		if not _ensure_steam_init():
			host_game_button.disabled = true
			join_game_button.disabled = true
			return
		host_game_button.disabled = false
		join_game_button.disabled = line_edit.text.is_empty()
	else:
		print("Network mode: LOCAL (ENet %s:%d)" % [local_address, local_port])
		host_game_button.disabled = false
		join_game_button.disabled = false

# Initialise Steam once, wiring the lobby callbacks a single time. Returns false on failure so
# callers can fall back. Safe to call repeatedly.
func _ensure_steam_init() -> bool:
	if _steam_ready:
		return true
	var init := Steam.steamInitEx(480, true)
	print("Steam init: ", init)
	if init["status"] != Steam.STEAM_API_INIT_RESULT_OK:
		push_error("Steam init failed (%d): %s" % [init["status"], init["verbal"]])
		return false
	Steam.initRelayNetworkAccess()
	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)
	_steam_ready = true
	return true

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


# --- Hosting ---------------------------------------------------------------

# Returns "" on success or a player-facing error. Steam hosting is async (the lobby arrives via
# _on_lobby_created), so it can only report the synchronous failures here; ENet reports inline.
func host_lobby() -> String:
	is_host = true
	if net_mode == NetMode.STEAM:
		Steam.createLobby(Steam.LobbyType.LOBBY_TYPE_PUBLIC, 16)
		return ""
	return _host_enet()

func _on_lobby_created(result: int, new_lobby_id: int):
	if result == Steam.Result.RESULT_OK:
		lobby_id = new_lobby_id

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


# --- Joining ---------------------------------------------------------------

func join_lobby(target_lobby_id: int):
	is_joining = true
	Steam.joinLobby(target_lobby_id)
	$UILayer.hide()

func _on_lobby_joined(joined_lobby_id: int, _permissions: int, _locked: bool, _response: int):
	if !is_joining:
		return

	lobby_id = joined_lobby_id
	var steam_peer := SteamMultiplayerPeer.new()
	steam_peer.server_relay = true
	steam_peer.create_client(Steam.getLobbyOwner(joined_lobby_id))
	peer = steam_peer
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected_to_server)

	is_joining = false

func _join_enet():
	var enet_peer := ENetMultiplayerPeer.new()
	var err := enet_peer.create_client(local_address, local_port)
	if err != OK:
		push_error("Failed to connect to %s:%d (error %d)" % [local_address, local_port, err])
		return
	peer = enet_peer
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	$UILayer.hide()


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


# --- UI --------------------------------------------------------------------

func _on_host_game_button_pressed() -> void:
	host_lobby()
	$UILayer.hide()

func _on_line_edit_text_changed(new_text: String) -> void:
	join_game_button.disabled = new_text.length() == 0

func _on_join_game_button_pressed() -> void:
	if net_mode == NetMode.STEAM:
		join_lobby(line_edit.text.to_int())
	else:
		_join_enet()

func _on_quit_pressed() -> void:
	get_tree().quit()
