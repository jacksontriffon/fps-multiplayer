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

# References



# Called when the node enters the scene tree for the first time.
func _ready():
	# Connect pause/play to TimeSystem
	pause_game.connect(Callable(TimeSystem, "pause"))
	play_game.connect(Callable(TimeSystem, "play"))

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


# --- HANDLE SIGNALS ---

func _input(event):
	# Handle Esc to close window
	if event.is_action_pressed("ui_cancel"):
		get_tree().quit()
