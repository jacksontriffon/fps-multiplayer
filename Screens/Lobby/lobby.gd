extends Node3D

enum NetMode { STEAM, LOCAL }

## Defaults to STEAM. Set to LOCAL in the inspector to test two windows on one
## machine over ENet loopback, bypassing Steam entirely. Leave as STEAM for real builds.
@export var net_mode: NetMode = NetMode.STEAM
@export var local_address: String = "127.0.0.1"
@export var local_port: int = 7777
@export var player_scene: PackedScene

var lobby_id: int = 0
var peer: MultiplayerPeer
var is_host: bool = false
var is_joining: bool = false

# Server-side team bookkeeping (only meaningful on the host, where _add_player
# runs). team_of maps peer id -> team index (0/1); slot_of maps peer id -> which
# spawn marker on that team's side it occupies. Slots are reclaimed on disconnect.
var team_of: Dictionary = {}
var slot_of: Dictionary = {}

@onready var join_game_button: Button = $CanvasLayer/CenterContainer/VBoxContainer/VBoxContainer/JoinGameButton
@onready var line_edit: LineEdit = $CanvasLayer/CenterContainer/VBoxContainer/VBoxContainer/LineEdit

# Spawn marker roots per team, populated in Lobby.tscn under SpawnPoints.
@onready var team_spawn_roots: Array[Node] = [
	$SpawnPoints/Team1,
	$SpawnPoints/Team2,
]


func _ready() -> void:
	if net_mode == NetMode.STEAM:
		print("Steam initialised: ", Steam.steamInit(480, true))
		Steam.initRelayNetworkAccess()
		Steam.lobby_created.connect(_on_lobby_created)
		Steam.lobby_joined.connect(_on_lobby_joined)
	else:
		print("Network mode: LOCAL (ENet %s:%d)" % [local_address, local_port])
		# No lobby id needed locally — join straight to loopback.
		join_game_button.disabled = false


# --- Hosting ---------------------------------------------------------------

func host_lobby():
	is_host = true
	if net_mode == NetMode.STEAM:
		Steam.createLobby(Steam.LobbyType.LOBBY_TYPE_PUBLIC, 16)
	else:
		_host_enet()

func _on_lobby_created(result: int, lobby_id: int):
	if result == Steam.Result.RESULT_OK:
		self.lobby_id = lobby_id

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

func join_lobby(lobby_id: int):
	is_joining = true
	Steam.joinLobby(lobby_id)
	$CanvasLayer.hide()

func _on_lobby_joined(lobby_id: int, permissions: int, locked: bool, response: int):
	if !is_joining:
		return

	self.lobby_id = lobby_id
	var steam_peer := SteamMultiplayerPeer.new()
	steam_peer.server_relay = true
	steam_peer.create_client(Steam.getLobbyOwner(lobby_id))
	peer = steam_peer
	multiplayer.multiplayer_peer = peer

	is_joining = false

func _join_enet():
	var enet_peer := ENetMultiplayerPeer.new()
	var err := enet_peer.create_client(local_address, local_port)
	if err != OK:
		push_error("Failed to connect to %s:%d (error %d)" % [local_address, local_port, err])
		return
	peer = enet_peer
	multiplayer.multiplayer_peer = peer
	$CanvasLayer.hide()


# --- Player spawn / despawn (transport-agnostic) ---------------------------

func _add_player(id: int = 1):
	# Balance teams as players arrive, then drop them onto the next free spawn
	# marker on their side. Both team and starting transform are part of the
	# player's spawn state (player.tscn), so they replicate to every peer.
	var team := _choose_team()
	var slot := _next_free_slot(team)
	team_of[id] = team
	slot_of[id] = slot

	var player = player_scene.instantiate()
	player.name = str(id)
	player.team = team

	var marker := _spawn_marker(team, slot)
	if marker:
		player.position = marker.global_position
		# Face the player toward the centre line (the marker's yaw); look is
		# driven by the Head node, which replicates its rotation at spawn.
		player.get_node("Head").rotation.y = marker.global_rotation.y

	call_deferred("add_child", player)

func _remove_player(id: int):
	team_of.erase(id)
	slot_of.erase(id)

	if !self.has_node(str(id)):
		print("Removing player id thatis not in Lobby")
		return

	self.get_node(str(id)).queue_free()


# --- Team assignment / spawn slots -----------------------------------------

# Put the new player on whichever side has fewer members (ties go to team 0).
func _choose_team() -> int:
	var counts := [0, 0]
	for pid in team_of:
		counts[team_of[pid]] += 1
	return 0 if counts[0] <= counts[1] else 1

# Lowest spawn index on this team not already taken by a connected member, so
# disconnected players' slots get reused rather than leaving gaps.
func _next_free_slot(team: int) -> int:
	var used := {}
	for pid in team_of:
		if team_of[pid] == team:
			used[slot_of[pid]] = true
	var i := 0
	while used.has(i):
		i += 1
	return i

# Resolve a (team, slot) pair to its Marker3D. Wraps if a side somehow gets more
# players than markers so we never index out of bounds.
func _spawn_marker(team: int, slot: int) -> Marker3D:
	var root := team_spawn_roots[team]
	var markers := root.get_children()
	if markers.is_empty():
		push_warning("No spawn markers for team %d" % team)
		return null
	return markers[slot % markers.size()]


# --- UI --------------------------------------------------------------------

func _on_host_game_button_pressed() -> void:
	host_lobby()
	$CanvasLayer.hide()

func _on_line_edit_text_changed(new_text: String) -> void:
	join_game_button.disabled = new_text.length() == 0

func _on_join_game_button_pressed() -> void:
	if net_mode == NetMode.STEAM:
		join_lobby(line_edit.text.to_int())
	else:
		_join_enet()
