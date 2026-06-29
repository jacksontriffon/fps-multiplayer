extends CanvasLayer

# Lobby menu, opened by interacting with the lobby pedestal. Two views:
#   • Classic — a big START that launches the Classic tournament (Team Battle across three
#     random maps, best of 3; see MatchManager).
#   • Customise — pick the game mode and map for a one-off match. Room to grow later.
# Local-only UI: the chosen flow is sent to the server on start, which owns the match
# (see MatchManager). The lobby roster is shown in both views.

@onready var main_view: Control = %MainView
@onready var customise_view: Control = %CustomiseView
@onready var mode_list: VBoxContainer = %ModeList
@onready var map_list: VBoxContainer = %MapList
@onready var player_list: VBoxContainer = %PlayerList
@onready var friend_separator: Control = %FriendSeparator
@onready var friend_heading: Control = %FriendHeading
@onready var friend_scroll: Control = %FriendScroll
@onready var friend_list: VBoxContainer = %FriendList
@onready var start_button: Button = %StartButton
@onready var customise_button: Button = %CustomiseButton
@onready var close_button: Button = %CloseButton
@onready var custom_start_button: Button = %CustomStartButton
@onready var customise_back_button: Button = %CustomiseBackButton
@onready var hint: Label = %Hint
@onready var net_row: Control = %NetRow
@onready var local_button: Button = %LocalButton
@onready var steam_button: Button = %SteamButton
@onready var error_label: Label = %ErrorLabel

# game.gd NetMode values, mirrored here so the toggle can read/set the host's transport.
const NET_STEAM := 0
const NET_LOCAL := 1

var _mode: int = Pedestal.GameMode.TEAM
var _selected_map: String = ""
var _map_group: ButtonGroup
var _mode_group: ButtonGroup
var _saved_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_VISIBLE
# Last roster rendered, so the player list is only rebuilt when someone joins or leaves.
var _roster_sig := ""
# Steam friend queries are throttled: the list only rebuilds when its contents change, and we only
# re-query every FRIEND_REFRESH seconds rather than every frame.
const FRIEND_REFRESH := 2.0
var _friend_sig := ""
var _friend_refresh_t := 0.0

func is_open() -> bool:
	return visible

func _ready() -> void:
	visible = false
	_build_mode_buttons()
	_build_map_buttons()
	start_button.pressed.connect(_on_start_tournament)
	customise_button.pressed.connect(_show_customise)
	custom_start_button.pressed.connect(_on_start_custom)
	customise_back_button.pressed.connect(_show_main)
	close_button.pressed.connect(close)
	var net_group := ButtonGroup.new()
	local_button.button_group = net_group
	steam_button.button_group = net_group
	local_button.pressed.connect(_on_net_mode.bind(NET_LOCAL))
	steam_button.pressed.connect(_on_net_mode.bind(NET_STEAM))

func open() -> void:
	_build_map_buttons()  # rebuilt each open so freshly saved player maps show up
	_select_default_mode()
	_select_default_map()
	_roster_sig = ""
	_friend_sig = ""
	_friend_refresh_t = 0.0
	_clear_error()
	_refresh_players()
	_refresh_friends()
	_update_start_state()
	_refresh_net_mode()
	_show_main()
	_saved_mouse_mode = Input.get_mouse_mode()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	visible = true

func close() -> void:
	if not visible:
		return
	visible = false
	Input.set_mouse_mode(_saved_mouse_mode)

func _show_main() -> void:
	main_view.visible = true
	customise_view.visible = false
	(close_button if start_button.disabled else start_button).grab_focus()

func _show_customise() -> void:
	main_view.visible = false
	customise_view.visible = true
	customise_back_button.grab_focus()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("quit_game") or event.is_action_pressed("ui_cancel"):
		# In Customise, step back to the main view first; otherwise close the menu.
		if customise_view.visible:
			_show_main()
		else:
			close()
		get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	if not visible:
		return
	# Close if a match started from elsewhere; otherwise keep the roster and Start state live.
	if MatchManager.state != MatchManager.State.WAITING:
		close()
		return
	_refresh_players()
	_update_start_state()
	_friend_refresh_t -= delta
	if _friend_refresh_t <= 0.0:
		_friend_refresh_t = FRIEND_REFRESH
		_refresh_friends()

func _build_mode_buttons() -> void:
	_mode_group = ButtonGroup.new()
	for mode in [Pedestal.GameMode.TEAM, Pedestal.GameMode.CAPTURE_THE_FLAG, Pedestal.GameMode.BATTLE_ROYALE, Pedestal.GameMode.RACE]:
		var b := Button.new()
		b.text = Pedestal.MODE_NAMES[mode]
		b.toggle_mode = true
		b.button_group = _mode_group
		b.custom_minimum_size = Vector2(200, 40)
		b.set_meta("mode", mode)
		b.pressed.connect(_on_mode_pressed.bind(b))
		mode_list.add_child(b)

func _on_mode_pressed(b: Button) -> void:
	_mode = b.get_meta("mode")

func _select_default_mode() -> void:
	for b in mode_list.get_children():
		if b is Button and b.get_meta("mode") == _mode:
			b.button_pressed = true
			return

func _build_map_buttons() -> void:
	for c in map_list.get_children():
		c.free()
	_map_group = ButtonGroup.new()
	for choice in MatchManager.map_choices():
		_add_map_button(choice["name"], choice["path"])
	# Player maps built in creative mode (saved to user://) — selectable for local testing.
	var player_maps: Array = CreativeManager.list_player_maps()
	if not player_maps.is_empty():
		var sep := HSeparator.new()
		map_list.add_child(sep)
		for choice in player_maps:
			_add_map_button(choice["name"] + "  (custom)", choice["path"])

func _add_map_button(label: String, path: String) -> void:
	var b := Button.new()
	b.text = label
	b.toggle_mode = true
	b.button_group = _map_group
	b.custom_minimum_size = Vector2(220, 40)
	b.set_meta("path", path)
	b.pressed.connect(_on_map_pressed.bind(b))
	map_list.add_child(b)

func _on_map_pressed(b: Button) -> void:
	_selected_map = b.get_meta("path")

# Re-press the current pick after a rebuild, or fall back to the first map. Keeps the player's
# choice across opens even as the player-map list grows.
func _select_default_map() -> void:
	for b in map_list.get_children():
		if b is Button and b.get_meta("path") == _selected_map:
			b.button_pressed = true
			return
	for b in map_list.get_children():
		if b is Button:
			b.button_pressed = true
			_selected_map = b.get_meta("path")
			return

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

# Friends who have played this game (in-game + Steam coplay history), each tagged with their
# status. In-game friends get a Join button; others just show Online/Offline. Local sessions can't
# reach Steam, so the section is hidden in that mode.
func _refresh_friends() -> void:
	var root := get_tree().get_first_node_in_group("game_root")
	var is_steam: bool = root != null and root.net_mode == NET_STEAM
	_set_friend_section_visible(is_steam)
	if not is_steam:
		_friend_sig = ""
		return
	# Friends already in our own lobby are shown in the roster above, so drop them here.
	var our_lobby: int = int(root.lobby_id)
	var shown: Array = []
	for entry in SteamFriends.list_played_with():
		if our_lobby != 0 and int(entry["lobby_id"]) == our_lobby:
			continue
		shown.append(entry)
	var sig := str(shown)
	if sig == _friend_sig:
		return
	_friend_sig = sig
	for c in friend_list.get_children():
		c.free()
	if shown.is_empty():
		var none := Label.new()
		none.text = "Play with someone to see them here"
		none.modulate = Color(1, 1, 1, 0.55)
		friend_list.add_child(none)
		return
	for entry in shown:
		_add_friend_row(entry)

func _set_friend_section_visible(v: bool) -> void:
	friend_separator.visible = v
	friend_heading.visible = v
	friend_scroll.visible = v

func _add_friend_row(entry: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var name_label := Label.new()
	name_label.text = entry["name"]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if not entry["online"]:
		name_label.modulate = Color(1, 1, 1, 0.5)
	row.add_child(name_label)
	if SteamFriends.can_join(entry):
		var join := Button.new()
		join.text = "Join"
		join.pressed.connect(_on_join_friend.bind(int(entry["lobby_id"])))
		row.add_child(join)
	else:
		var status := Label.new()
		status.text = "In game" if entry["in_game"] else ("Online" if entry["online"] else "Offline")
		status.modulate = Color(1, 1, 1, 0.55)
		status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(status)
	friend_list.add_child(row)

func _on_join_friend(lobby_id: int) -> void:
	var root := get_tree().get_first_node_in_group("game_root")
	if root == null:
		return
	root.leave_and_join_lobby(lobby_id)
	close()

func _update_start_state() -> void:
	var ready := MatchManager.can_start()
	start_button.disabled = not ready
	custom_start_button.disabled = not ready
	hint.text = "" if ready else "Need at least %d players to start" % MatchManager.MIN_PLAYERS

func _on_start_tournament() -> void:
	if not MatchManager.can_start():
		return
	if multiplayer.is_server():
		MatchManager.server_request_start_tournament()
	else:
		MatchManager.request_start_tournament.rpc_id(1)
	close()

func _on_start_custom() -> void:
	if not MatchManager.can_start():
		return
	if multiplayer.is_server():
		MatchManager.server_request_start(_mode, _selected_map)
	else:
		MatchManager.request_start.rpc_id(1, _mode, _selected_map)
	close()

# The Local/Steam toggle only makes sense for the host (it owns the transport), so it's hidden
# for clients. Reflects the session's current mode.
func _refresh_net_mode() -> void:
	var root := get_tree().get_first_node_in_group("game_root")
	var is_host := multiplayer.has_multiplayer_peer() and multiplayer.is_server()
	net_row.visible = is_host and root != null
	if root == null:
		return
	if root.net_mode == NET_LOCAL:
		local_button.button_pressed = true
	else:
		steam_button.button_pressed = true

# Switching transport re-hosts the session. On success the menu closes (its player is about to
# respawn); on failure the session is untouched, so keep the menu open and show why.
func _on_net_mode(mode: int) -> void:
	var root := get_tree().get_first_node_in_group("game_root")
	if root == null or root.net_mode == mode:
		return
	_clear_error()
	var err: String = root.switch_net_mode(mode)
	if err != "":
		_show_error(err)
		_refresh_net_mode()  # re-sync the toggle to the mode that's actually active
		return
	close()

func _show_error(text: String) -> void:
	error_label.text = text
	error_label.visible = true

func _clear_error() -> void:
	error_label.text = ""
	error_label.visible = false
