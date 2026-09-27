extends CanvasLayer

# Escape overlay: a simple panel with Continue and Quit. Purely cosmetic — it does
# not pause the tree or touch networked state, it only shows the panel and frees the
# mouse so the buttons are clickable, restoring the prior mouse mode on continue.

@onready var continue_button: Button = %ContinueButton
@onready var lobby_button: Button = %LobbyButton
@onready var quit_button: Button = %QuitButton

# Dev-only map-building tools, shown only when the game root has dev_mode on.
@onready var dev_tools: VBoxContainer = %DevTools
@onready var creative_toggle: CheckButton = %CreativeToggle
@onready var map_name_edit: LineEdit = %MapNameEdit
@onready var save_layout_button: Button = %SaveLayoutButton
@onready var save_map_button: Button = %SaveMapButton
@onready var add_build_button: Button = %AddBuildButton
@onready var dev_status: Label = %DevStatus

var _saved_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_VISIBLE

# True while the overlay is showing. Read by the local player's input handlers so
# controls are ignored (but physics keeps running) while the menu is up.
func is_open() -> bool:
	return visible

func _ready() -> void:
	visible = false
	continue_button.pressed.connect(close)
	lobby_button.pressed.connect(_on_lobby)
	quit_button.pressed.connect(func() -> void: get_tree().quit())
	creative_toggle.toggled.connect(_on_creative_toggled)
	save_layout_button.pressed.connect(_on_save_layout)
	save_map_button.pressed.connect(_on_save_map)
	add_build_button.pressed.connect(_on_add_build)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("quit_game"):
		if visible:
			close()
		else:
			open()
		get_viewport().set_input_as_handled()

func open() -> void:
	_saved_mouse_mode = Input.get_mouse_mode()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	# Nothing to leave when already in the lobby — only offer it mid-match.
	lobby_button.visible = MatchManager.state != MatchManager.State.WAITING
	_refresh_dev_tools()
	visible = true
	continue_button.grab_focus()

func close() -> void:
	visible = false
	Input.set_mouse_mode(_saved_mouse_mode)

# Abandon the current match and send everyone back to the lobby (server owns the flow).
func _on_lobby() -> void:
	if multiplayer.is_server():
		MatchManager.server_request_to_lobby()
	elif multiplayer.has_multiplayer_peer():
		MatchManager.request_to_lobby.rpc_id(1)
	close()

# --- Dev tools -------------------------------------------------------------

# Show the dev tools only when the build has dev_mode on; creative is available any time from
# there (including mid-match). Sync the toggle to the local player's current state.
func _refresh_dev_tools() -> void:
	var root := get_tree().get_first_node_in_group("game_root")
	var dev: bool = root != null and root.dev_mode
	dev_tools.visible = dev
	dev_status.text = ""
	if not dev:
		return
	var creative := _local_creative()
	creative_toggle.set_pressed_no_signal(creative != null and creative.active)

func _on_creative_toggled(pressed: bool) -> void:
	var creative := _local_creative()
	if creative == null:
		return
	creative.set_active(pressed)
	# set_active can refuse (e.g. not allowed) — reflect the real state back.
	creative_toggle.set_pressed_no_signal(creative.active)

func _on_save_layout() -> void:
	dev_status.text = _result_text(CreativeManager.save_layout(), "Layout saved.")

func _on_save_map() -> void:
	dev_status.text = _result_text(CreativeManager.save_as_new_map(map_name_edit.text), "Saved as new map.")

func _on_add_build() -> void:
	dev_status.text = _result_text(CreativeManager.add_map_to_build(map_name_edit.text), "Added to game build.")

func _result_text(err: String, ok: String) -> String:
	return ok if err == "" else err

# The local player's creative controller (the authority-owned player body).
func _local_creative() -> CreativeMode:
	for p in get_tree().get_nodes_in_group("players"):
		if p is Player and p.is_multiplayer_authority():
			return p.creative_controller()
	return null
