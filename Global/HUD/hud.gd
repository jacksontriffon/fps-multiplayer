extends CanvasLayer

# Reads mirrored MatchManager state each frame; only the host's Start button writes
# back (to request a match start).

const TEAM_NAMES := ["Red", "Blue"]
const BANNER_HOLD := 2.5
const DOT_SLOTS := 8

@onready var lives_label: Label = $Root/Lives
@onready var score_label: Label = $Root/Score
@onready var red_dots: Label = $Root/Top/RedDots
@onready var blue_dots: Label = $Root/Top/BlueDots
@onready var start_button: Button = $Root/Top/StartButton
@onready var banner_label: Label = $Root/Banner

var _last_banner_text := ""
var _banner_age := 0.0
var _cursor_freed := false

func _ready() -> void:
	start_button.pressed.connect(_on_start_pressed)

func _process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer():
		visible = false
		return
	visible = true
	var id := multiplayer.get_unique_id()
	_update_lives(id)
	_update_score()
	_update_dots()
	_update_start_button()
	_update_banner(delta)

func _on_start_pressed() -> void:
	MatchManager.server_request_start()

func _update_lives(id: int) -> void:
	if MatchManager.state == MatchManager.State.WAITING or not MatchManager.lives.has(id):
		lives_label.text = ""
		return
	var n: int = MatchManager.lives[id]
	if n <= 0:
		lives_label.text = "ELIMINATED — spectating"
		lives_label.modulate = Color(1, 1, 1, 0.7)
	else:
		lives_label.text = "Lives  " + "● ".repeat(n).strip_edges()
		lives_label.modulate = Color.WHITE

func _update_score() -> void:
	if MatchManager.state == MatchManager.State.WAITING:
		score_label.text = ""
		return
	var r: int = MatchManager.team_scores[0]
	var b: int = MatchManager.team_scores[1]
	score_label.text = "%s  %d  —  %d  %s" % [TEAM_NAMES[0], r, b, TEAM_NAMES[1]]

func _update_dots() -> void:
	var counts: Array = MatchManager.get_team_counts()
	red_dots.text = "%s  %s" % [TEAM_NAMES[0], _dots(counts[0])]
	blue_dots.text = "%s  %s" % [TEAM_NAMES[1], _dots(counts[1])]

func _dots(n: int) -> String:
	var lit: int = clampi(n, 0, DOT_SLOTS)
	return ("● ".repeat(lit) + "○ ".repeat(DOT_SLOTS - lit)).strip_edges()

func _update_start_button() -> void:
	var is_host := multiplayer.get_unique_id() == 1
	var show_start := is_host and MatchManager.can_start()
	start_button.visible = show_start
	# Free the cursor so the host can click Start; recapture once it's gone.
	if show_start:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif _cursor_freed:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_cursor_freed = show_start

func _update_banner(delta: float) -> void:
	if MatchManager.state == MatchManager.State.WAITING:
		banner_label.text = _waiting_text()
		_last_banner_text = banner_label.text
		return
	var text: String = MatchManager.status_text
	if text != _last_banner_text:
		_last_banner_text = text
		_banner_age = 0.0
	else:
		_banner_age += delta
	var hold := MatchManager.state == MatchManager.State.PLAYING
	if hold and _banner_age > BANNER_HOLD:
		banner_label.text = ""
	else:
		banner_label.text = text

func _waiting_text() -> String:
	var counts: Array = MatchManager.get_team_counts()
	var ready: bool = counts[0] >= MatchManager.MIN_PER_TEAM and counts[1] >= MatchManager.MIN_PER_TEAM
	if not ready:
		return "Waiting for players..."
	if multiplayer.get_unique_id() == 1:
		return ""
	return "Waiting for host to start..."
