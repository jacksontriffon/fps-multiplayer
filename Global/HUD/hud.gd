extends CanvasLayer

# Reads mirrored MatchManager state plus the lobby podium each frame; never writes.

const TEAM_NAMES := ["Red", "Blue"]
const BANNER_HOLD := 2.5

@onready var lives_label: Label = $Root/Lives
@onready var score_label: Label = $Root/Score
@onready var banner_label: Label = $Root/Banner
@onready var damage_indicator = $Root/DamageIndicator

# Called on the struck player's authority peer. world_dir points from the player
# toward where the hit came from (the negated knockback impulse).
func hit_from(world_dir: Vector3) -> void:
	damage_indicator.register_hit(world_dir)

var _last_banner_text := ""
var _banner_age := 0.0

func _process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer():
		visible = false
		return
	visible = true
	var id := multiplayer.get_unique_id()
	_update_lives(id)
	_update_score()
	_update_banner(delta)

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

func _update_banner(delta: float) -> void:
	if MatchManager.state == MatchManager.State.WAITING:
		banner_label.text = ""
		_last_banner_text = ""
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
