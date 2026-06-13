extends Node3D
class_name PlayerHead

# First-person look + the local camera. Only the authority peer drives the mouse,
# but Head.rotation (yaw) and Camera3D.rotation (pitch) are replicated by the
# player's MultiplayerSynchronizer, so remote players visibly look around.

const SENSITIVITY = 0.003
const PITCH_LIMIT = deg_to_rad(45)
# Mouse look is per-pixel (already frame-rate independent); stick look is a held
# axis, so it scales by delta. Radians/sec at full deflection. Both are scaled by
# the user's sensitivity multipliers (Global.mouse_sensitivity / joypad_sensitivity).
const JOYPAD_LOOK_SPEED = 3.0

# Local-only hit shake. Trauma builds on a hit and decays each second; the actual
# offset is trauma-squared so it falls off smoothly. Driven through h_offset/v_offset
# (frustum shift) rather than rotation, which is replicated and owned by look.
const TRAUMA_DECAY = 1.8
const SHAKE_MAX_OFFSET = 0.12

var _trauma := 0.0

@onready var camera: Camera3D = $Camera3D
@onready var crosshairs: CanvasLayer = %Crosshairs
@onready var charge_bar: ProgressBar = %ChargeBar
@onready var hands: Hands = $Camera3D/Hands
@onready var _player: Player = get_parent() as Player


func _ready() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	if not is_multiplayer_authority():
		return
	camera.make_current()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	crosshairs.visible = true

func _process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	if not is_multiplayer_authority():
		return
	# No first-person look while stunned (the body's tumble drives the camera) or dead
	# (the spectator camera takes over).
	if _player and not _player.controllable():
		return
	# Right-stick look. get_vector applies the actions' deadzone; mouse look is
	# handled separately in _unhandled_input. Both feed _apply_look. Skipped while the
	# pause overlay is up so the stick can't steer the camera (mouse look is gated there).
	if not Global.is_input_blocked():
		var look := Input.get_vector("look_left", "look_right", "look_up", "look_down")
		if look != Vector2.ZERO:
			var speed := JOYPAD_LOOK_SPEED * Global.joypad_sensitivity * delta
			_apply_look(-look.x * speed, -look.y * speed)
	# Local-only charge bar for the player winding up a throw.
	var charging := hands.is_charging()
	charge_bar.visible = charging
	if charging:
		charge_bar.value = hands.get_charge()
	_update_shake(delta)

# Called on the local authority when a ball lands. Trauma stacks toward 1.0.
func add_trauma(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)

func _update_shake(delta: float) -> void:
	if _trauma <= 0.0:
		camera.h_offset = 0.0
		camera.v_offset = 0.0
		return
	var shake := _trauma * _trauma
	camera.h_offset = SHAKE_MAX_OFFSET * shake * randf_range(-1.0, 1.0)
	camera.v_offset = SHAKE_MAX_OFFSET * shake * randf_range(-1.0, 1.0)
	_trauma = maxf(0.0, _trauma - TRAUMA_DECAY * delta)

func _unhandled_input(event: InputEvent) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	if not is_multiplayer_authority():
		return
	if _player and not _player.controllable():
		return
	# Ignore mouse look while the cursor is free (e.g. the pause overlay is open).
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		var s := SENSITIVITY * Global.mouse_sensitivity
		_apply_look(-event.relative.x * s, -event.relative.y * s)

# Shared look path for mouse and stick: yaw on the head, pitch on the camera (clamped).
func _apply_look(yaw_delta: float, pitch_delta: float) -> void:
	rotate_y(yaw_delta)
	camera.rotate_x(pitch_delta)
	camera.rotation.x = clamp(camera.rotation.x, -PITCH_LIMIT, PITCH_LIMIT)
