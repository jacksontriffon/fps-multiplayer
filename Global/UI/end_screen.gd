extends CanvasLayer

# End-of-match overlay. While a match is over it shows the result plus two choices: Rematch
# (replay the same mode + map, or a fresh tournament) and Return to Lobby. Both route through
# the server like the lobby Start, so any peer can trigger them. If nobody acts, MatchManager
# auto-returns everyone to the lobby after END_SCREEN_LINGER (and respawns them there) — this
# screen just lets players act sooner. Local-only UI; it reads replicated MatchManager state.

@onready var result_label: Label = %Result
@onready var rematch_button: Button = %RematchButton
@onready var lobby_button: Button = %LobbyButton

var _saved_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_VISIBLE

func _ready() -> void:
	visible = false
	rematch_button.pressed.connect(_on_rematch)
	lobby_button.pressed.connect(_on_lobby)

func _process(_delta: float) -> void:
	var over := multiplayer.has_multiplayer_peer() and MatchManager.state == MatchManager.State.MATCH_OVER
	if over and not visible:
		_open()
	elif not over and visible:
		_close()
	if visible:
		result_label.text = MatchManager.status_text

func _open() -> void:
	_saved_mouse_mode = Input.get_mouse_mode()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	visible = true
	rematch_button.grab_focus()

func _close() -> void:
	visible = false
	Input.set_mouse_mode(_saved_mouse_mode)

# Replay the same match. The server validates (still MATCH_OVER, enough players); the state
# change it broadcasts closes this screen on every peer.
func _on_rematch() -> void:
	if multiplayer.is_server():
		MatchManager.server_request_rematch()
	elif multiplayer.has_multiplayer_peer():
		MatchManager.request_rematch.rpc_id(1)

func _on_lobby() -> void:
	if multiplayer.is_server():
		MatchManager.server_request_to_lobby()
	elif multiplayer.has_multiplayer_peer():
		MatchManager.request_to_lobby.rpc_id(1)
