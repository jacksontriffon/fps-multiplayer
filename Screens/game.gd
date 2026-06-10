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

var lobby_id: int = 0
var peer: MultiplayerPeer
var is_host: bool = false
var is_joining: bool = false
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

	if net_mode == NetMode.STEAM:
		var init := Steam.steamInitEx(480, true)
		print("Steam init: ", init)
		if init["status"] != Steam.STEAM_API_INIT_RESULT_OK:
			push_error("Steam init failed (%d): %s" % [init["status"], init["verbal"]])
			host_game_button.disabled = true
			join_game_button.disabled = true
			return
		Steam.initRelayNetworkAccess()
		Steam.lobby_created.connect(_on_lobby_created)
		Steam.lobby_joined.connect(_on_lobby_joined)
	else:
		print("Network mode: LOCAL (ENet %s:%d)" % [local_address, local_port])
		join_game_button.disabled = false

	host_game_button.grab_focus()


# --- Map swapping ----------------------------------------------------------

# Swap MapContainer's single child to `path`. call_local so the host loads too; every peer
# instances the same scene named "Map" → identical node paths for the synchronizers inside.
@rpc("authority", "call_local", "reliable")
func load_map(path: String) -> void:
	current_map_path = path
	for c in map_container.get_children():
		c.free()  # immediate, not queue_free: never let two maps coexist for a frame
	var inst := (load(path) as PackedScene).instantiate()
	inst.name = "Map"
	map_container.add_child(inst)

# Pull model for late joiners: a client asks once it is connected, the server replies with the
# live map. Avoids a client receiving load_map before its MapContainer exists.
@rpc("any_peer", "reliable")
func request_current_map() -> void:
	if not multiplayer.is_server():
		return
	load_map.rpc_id(multiplayer.get_remote_sender_id(), current_map_path)

func _on_connected_to_server() -> void:
	request_current_map.rpc_id(1)


# --- Hosting ---------------------------------------------------------------

func host_lobby():
	is_host = true
	if net_mode == NetMode.STEAM:
		Steam.createLobby(Steam.LobbyType.LOBBY_TYPE_PUBLIC, 16)
	else:
		_host_enet()

func _on_lobby_created(result: int, new_lobby_id: int):
	if result == Steam.Result.RESULT_OK:
		lobby_id = new_lobby_id

		var steam_peer := SteamMultiplayerPeer.new()
		steam_peer.server_relay = true
		steam_peer.create_host()
		_start_host(steam_peer)

		print("Lobby created: ID #", lobby_id)

func _host_enet():
	var enet_peer := ENetMultiplayerPeer.new()
	var err := enet_peer.create_server(local_port)
	if err != OK:
		push_error("Failed to create ENet server on port %d (error %d)" % [local_port, err])
		return
	_start_host(enet_peer)
	print("ENet server listening on port ", local_port)

# Shared host setup for either transport.
func _start_host(new_peer: MultiplayerPeer):
	peer = new_peer
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_add_player)
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
	var spawner := get_tree().get_first_node_in_group("spawn_points")
	if spawner:
		# Lobby spawn: any free spot, teamless (player.team -1 reads as neutral grey).
		var spawn: Dictionary = spawner.reserve_any(id)
		player.team = spawn["team"]
		player.position = spawn["position"]
		player.get_node("Head").rotation.y = spawn["yaw"]
	call_deferred("add_child", player)

func _remove_player(id: int):
	var spawner := get_tree().get_first_node_in_group("spawn_points")
	if spawner:
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
