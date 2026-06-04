extends Node3D

var lobby_id: int = 0
var peer : SteamMultiplayerPeer
@export var player_scene: PackedScene
var is_host: bool = false
var is_joining: bool = false

@onready var join_game_button: Button = $CanvasLayer/CenterContainer/VBoxContainer/VBoxContainer/JoinGameButton
@onready var line_edit: LineEdit = $CanvasLayer/CenterContainer/VBoxContainer/VBoxContainer/LineEdit


func _ready() -> void:
	print("Steam initialised: ", Steam.steamInit(480, true))
	Steam.initRelayNetworkAccess()
	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)

func host_lobby():
	Steam.createLobby(Steam.LobbyType.LOBBY_TYPE_PUBLIC, 16)
	is_host = true

func _on_lobby_created(result: int, lobby_id: int):
	if result == Steam.Result.RESULT_OK:
		self.lobby_id = lobby_id
		
		peer = SteamMultiplayerPeer.new()
		peer.server_relay = true
		peer.create_host()
		
		multiplayer.multiplayer_peer = peer
		multiplayer.peer_connected.connect(_add_player)
		multiplayer.peer_disconnected.connect(_remove_player)
		_add_player()
		
		print("Lobby created: ID #", lobby_id)

func join_lobby(lobby_id: int):
	is_joining = true
	Steam.joinLobby(lobby_id)
	$CanvasLayer.hide()

func _on_lobby_joined(lobby_id: int, permissions: int, locked: bool, response: int):
	if !is_joining:
		return
	
	self.lobby_id = lobby_id
	peer = SteamMultiplayerPeer.new()
	peer.server_relay = true
	peer.create_client(Steam.getLobbyOwner(lobby_id))
	multiplayer.multiplayer_peer = peer
	
	is_joining = false

func _add_player(id: int = 1):
	var player = player_scene.instantiate()
	player.name = str(id)
	call_deferred("add_child", player)

func _remove_player(id: int):
	if !self.has_node(str(id)):
		print("Removing player id thatis not in Lobby")
		return
	
	self.get_node(str(id)).queue_free()


func _on_host_game_button_pressed() -> void:
	host_lobby()
	$CanvasLayer.hide()


func _on_line_edit_text_changed(new_text: String) -> void:
	join_game_button.disabled = new_text.length() == 0

func _on_join_game_button_pressed() -> void:
	join_lobby(line_edit.text.to_int())
