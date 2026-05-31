extends Node

# Exports

# Signals
signal new_second
signal new_minute
signal new_hour

# State
var paused := true
var previous_game_second: int
var game_second: float = 0 # Raw seconds (not rounded)
var total_seconds_played: int
var total_minutes_played: int
var total_hours_played: int

# References



# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass

	# --- CONNECT TO SIGNALS ---


func _process(delta: float) -> void:
	if not paused:
		# Start time
		game_second += 1 * delta
		
		# Update every second
		if round(game_second) != previous_game_second:
			secondly_update()


func pause() -> void:
	paused = true

func play() -> void:
	paused = false

func reset() -> void:
	total_seconds_played = 0
	total_minutes_played = 0
	total_hours_played = 0
	game_second = 0.0
	previous_game_second = 0

# --- TIME UPDATES ---
func secondly_update():
	total_seconds_played += 1
	previous_game_second = round(game_second) # Keep loop going
	new_second.emit()
	
	# Check for new minute
	if total_seconds_played % 60 == 0:
		total_minutes_played += 1
		new_minute.emit()
		
		# Check for new hour
		if total_minutes_played % 60 == 0:
			total_hours_played += 1
			new_hour.emit()
	
	gametime_log() # See game running

func gametime_log():
	print(round(total_seconds_played), ' sec played')
#	print(round(game_second), ' game second')

func get_time_string() -> String:
	var hours = total_hours_played
	var minutes = total_minutes_played % 60
	var seconds = total_seconds_played % 60
	return "%02d:%02d:%02d" % [hours, minutes, seconds]


# --- HANDLE SIGNALS ---
