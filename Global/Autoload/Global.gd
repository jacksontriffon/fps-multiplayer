extends Node

# Exports

# Signals
signal pause_game
signal pause_game_movement
signal play_game
signal play_game_movement
signal restart

signal screen_shake(intensity: float, time: float, limit: float)

signal fade_out(time: float)
signal fade_in(time: float)

# State
var paused := true
var paused_movement := false

# Look sensitivity multipliers (1.0 = baseline feel). Applied by Head/head.gd to
# both mouse and joypad look, and persisted via SaveSystem.
var mouse_sensitivity := 1.0
var joypad_sensitivity := 1.0

# References



# Called when the node enters the scene tree for the first time.
func _ready():
	# Connect pause/play to TimeSystem
	pause_game.connect(Callable(TimeSystem, "pause"))
	play_game.connect(Callable(TimeSystem, "play"))

	# Deferred so SaveSystem (a later autoload) has populated game_data first.
	_load_settings.call_deferred()

	# --- CONNECT TO SIGNALS ---


func pause() -> void:
	paused = true
	pause_game.emit()

func pause_movement() -> void:
	paused_movement = true
	pause_game_movement.emit()

func play_movement() -> void:
	paused_movement = false
	play_game_movement.emit()

func play() -> void:
	paused = false
	play_game.emit()

func restart_game() -> void:
	TimeSystem.reset()
	restart.emit()


# --- SETTINGS ---

func _load_settings() -> void:
	mouse_sensitivity = SaveSystem.game_data.get("mouse_sensitivity", 1.0)
	joypad_sensitivity = SaveSystem.game_data.get("joypad_sensitivity", 1.0)

# Persisted setter for a future options menu to call.
func set_look_sensitivity(mouse: float, joypad: float) -> void:
	mouse_sensitivity = maxf(mouse, 0.01)
	joypad_sensitivity = maxf(joypad, 0.01)
	SaveSystem.game_data["mouse_sensitivity"] = mouse_sensitivity
	SaveSystem.game_data["joypad_sensitivity"] = joypad_sensitivity
	SaveSystem.save_data()


# --- HANDLE SIGNALS ---

func _input(event):
	# Dedicated quit action (not ui_cancel) so menu-back / gameplay buttons that
	# share ui_cancel don't close the whole game.
	if event.is_action_pressed("quit_game"):
		get_tree().quit()
