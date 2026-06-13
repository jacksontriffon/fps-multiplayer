extends CanvasLayer

# Pre-match setup overlay, opened by interacting with a lobby pedestal instead of starting
# instantly. Shows the game mode, a selectable list of maps, and the players currently in the
# lobby, then starts the match on the chosen map. Local-only UI: the chosen mode and map are
# sent to the server on Start, which owns the actual match flow (see MatchManager).

@onready var mode_title: Label = %ModeTitle
@onready var map_list: VBoxContainer = %MapList
@onready var player_list: VBoxContainer = %PlayerList
@onready var start_button: Button = %StartButton
@onready var back_button: Button = %BackButton
@onready var hint: Label = %Hint

var _mode: int = Pedestal.GameMode.TEAM
var _selected_map: String = ""
var _map_group: ButtonGroup
var _saved_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_VISIBLE
# Last roster rendered, so the player list is only rebuilt when someone joins or leaves.
var _roster_sig := ""

func is_open() -> bool:
	return visible

func _ready() -> void:
	visible = false
	_build_map_buttons()
	start_button.pressed.connect(_on_start)
	back_button.pressed.connect(close)

func open(mode: int) -> void:
	_mode = mode
	mode_title.text = "Set Up %s" % Pedestal.MODE_NAMES[mode]
	_select_default_map()
	_roster_sig = ""
	_refresh_players()
	_update_start_state()
	_saved_mouse_mode = Input.get_mouse_mode()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	visible = true
	(back_button if start_button.disabled else start_button).grab_focus()

func close() -> void:
	if not visible:
		return
	visible = false
	Input.set_mouse_mode(_saved_mouse_mode)

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("quit_game") or event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	if not visible:
		return
	# Close if a match started from elsewhere; otherwise keep the roster and Start state live.
	if MatchManager.state != MatchManager.State.WAITING:
		close()
		return
	_refresh_players()
	_update_start_state()

func _build_map_buttons() -> void:
	_map_group = ButtonGroup.new()
	for choice in MatchManager.MAP_CHOICES:
		var b := Button.new()
		b.text = choice["name"]
		b.toggle_mode = true
		b.button_group = _map_group
		b.custom_minimum_size = Vector2(220, 40)
		b.set_meta("path", choice["path"])
		b.pressed.connect(_on_map_pressed.bind(b))
		map_list.add_child(b)

func _on_map_pressed(b: Button) -> void:
	_selected_map = b.get_meta("path")

# Preselect the mode's default map, falling back to the first in the list.
func _select_default_map() -> void:
	var default_path: String = MatchManager.MAP_OF.get(_mode, "")
	var first: Button = null
	for b in map_list.get_children():
		if b is Button:
			if first == null:
				first = b
			if b.get_meta("path") == default_path:
				b.button_pressed = true
				_selected_map = default_path
				return
	if first:
		first.button_pressed = true
		_selected_map = first.get_meta("path")

func _refresh_players() -> void:
	var ids := MatchManager.roster()
	var sig := str(ids)
	if sig == _roster_sig:
		return
	_roster_sig = sig
	for c in player_list.get_children():
		c.free()
	var local_id := multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 0
	for id in ids:
		var label := Label.new()
		var who := "Player %d" % id
		if id == 1:
			who += "  (Host)"
		if id == local_id:
			who += "  — You"
		label.text = who
		player_list.add_child(label)

func _update_start_state() -> void:
	var ready := MatchManager.can_start()
	start_button.disabled = not ready
	hint.text = "" if ready else "Need at least %d players to start" % MatchManager.MIN_PLAYERS

func _on_start() -> void:
	if not MatchManager.can_start():
		return
	if multiplayer.is_server():
		MatchManager.server_request_start(_mode, _selected_map)
	else:
		MatchManager.request_start.rpc_id(1, _mode, _selected_map)
	close()
