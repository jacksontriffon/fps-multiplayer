extends CanvasLayer

# Reads mirrored MatchManager state plus the lobby podium each frame; never writes.
# The bottom bar holds lives (left), ability/item slots (centre) and the carried-ball
# count (right). Slots are empty placeholders for now; fill them via set_slot().

const TEAM_NAMES := ["Red", "Blue"]
const BANNER_HOLD := 2.5
const HEART_FULL := preload("res://Assets/Textures/UI/heart_full.svg")
const HEART_EMPTY := preload("res://Assets/Textures/UI/heart_empty.svg")
const HEART_SIZE := Vector2(28, 28)

@onready var bottom_bar: PanelContainer = $Root/BottomBar
@onready var lives_box: HBoxContainer = $Root/BottomBar/Row/LivesSection/Lives
@onready var lives_text: Label = $Root/BottomBar/Row/LivesSection/LivesText
@onready var slots_box: HBoxContainer = $Root/BottomBar/Row/Slots
@onready var ball_icon: TextureRect = $Root/BottomBar/Row/AmmoSection/BallIcon
@onready var ammo_count: Label = $Root/BottomBar/Row/AmmoSection/AmmoCount
@onready var score_label: Label = $Root/Score
@onready var banner_label: Label = $Root/Banner

var _last_banner_text := ""
var _banner_age := 0.0

func _process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer():
		visible = false
		return
	visible = true
	var id := multiplayer.get_unique_id()
	_update_bar(id)
	_update_score()
	_update_banner(delta)

func _update_bar(id: int) -> void:
	var playing := MatchManager.state != MatchManager.State.WAITING and MatchManager.lives.has(id)
	bottom_bar.visible = playing
	if not playing:
		return
	var n: int = MatchManager.lives[id]
	_update_lives(n)
	_update_ammo(id, n > 0)

func _update_lives(n: int) -> void:
	if n <= 0:
		lives_box.visible = false
		lives_text.visible = true
		lives_text.text = "ELIMINATED"
		lives_text.modulate = Color(1, 1, 1, 0.7)
		return
	lives_text.visible = false
	lives_box.visible = true
	var total: int = max(MatchManager.STARTING_LIVES, n)
	_ensure_hearts(total)
	for i in lives_box.get_child_count():
		var heart: TextureRect = lives_box.get_child(i)
		heart.texture = HEART_FULL if i < n else HEART_EMPTY

func _ensure_hearts(count: int) -> void:
	while lives_box.get_child_count() < count:
		var heart := TextureRect.new()
		heart.custom_minimum_size = HEART_SIZE
		heart.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		heart.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		lives_box.add_child(heart)
	while lives_box.get_child_count() > count:
		lives_box.get_child(lives_box.get_child_count() - 1).free()

func _update_ammo(id: int, alive: bool) -> void:
	var carried := 0
	for b in get_tree().get_nodes_in_group("grabbable"):
		if b is Grabbable and b.held_by == id:
			carried += 1
	ammo_count.text = "×%d" % carried
	var dim := 0.4 if (carried == 0 or not alive) else 1.0
	ball_icon.modulate = Color(1, 1, 1, dim)
	ammo_count.modulate = Color(1, 1, 1, dim)

# Fill or clear a centre slot for a future item/ability. Pass null to empty it.
func set_slot(index: int, texture: Texture2D) -> void:
	if index < 0 or index >= slots_box.get_child_count():
		return
	var icon := slots_box.get_child(index).get_node("Icon") as TextureRect
	icon.texture = texture
	icon.visible = texture != null

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
