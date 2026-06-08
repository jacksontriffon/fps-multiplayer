extends CanvasLayer

# Escape overlay: a simple panel with Continue and Quit. Purely cosmetic — it does
# not pause the tree or touch networked state, it only shows the panel and frees the
# mouse so the buttons are clickable, restoring the prior mouse mode on continue.

@onready var continue_button: Button = %ContinueButton
@onready var quit_button: Button = %QuitButton

var _saved_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_VISIBLE

# True while the overlay is showing. Read by the local player's input handlers so
# controls are ignored (but physics keeps running) while the menu is up.
func is_open() -> bool:
	return visible

func _ready() -> void:
	visible = false
	continue_button.pressed.connect(close)
	quit_button.pressed.connect(func() -> void: get_tree().quit())

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
	visible = true
	continue_button.grab_focus()

func close() -> void:
	visible = false
	Input.set_mouse_mode(_saved_mouse_mode)
