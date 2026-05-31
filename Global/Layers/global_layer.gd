extends CanvasLayer

# Exports

# Signals

# State

# References
@onready var overlay: ColorRect = %Overlay



# Called when the node enters the scene tree for the first time.
func _ready() -> void:


	# --- CONNECT TO SIGNALS ---
	Global.connect("fade_in", fade_in)
	Global.connect("fade_out", fade_out)

func fade_out(time: float = 0.5) -> void:
	create_tween().tween_property(overlay, 'modulate:a', 1.0, time)

func fade_in(time: float = 0.5) -> void:
	create_tween().tween_property(overlay, 'modulate:a', 0.0, time)

# --- HANDLE SIGNALS ---


