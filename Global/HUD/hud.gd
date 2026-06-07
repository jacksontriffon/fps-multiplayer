extends CanvasLayer

# Reads mirrored MatchManager state plus the lobby podium each frame; never writes.
# The bottom bar holds lives (left) and ability/item slots (right). Slots are empty
# placeholders for now; fill them via set_slot().

const TEAM_NAMES := ["Red", "Blue"]
const BANNER_HOLD := 2.5
const PULSE_DECAY := 0.6
const RAMP_MAX := 0.25
const HEART_FULL := preload("res://Assets/Textures/UI/heart_full.svg")
const HEART_EMPTY := preload("res://Assets/Textures/UI/heart_empty.svg")
const HEART_SIZE := Vector2(28, 28)

@onready var bottom_bar: HBoxContainer = %BottomBar
@onready var lives_box: HBoxContainer = %Lives
@onready var lives_text: Label = %LivesText
@onready var stamina_bar: ProgressBar = %Stamina
@onready var slots_box: HBoxContainer = %Slots
@onready var score_label: Label = %Score
@onready var banner_label: Label = %Banner
@onready var hurt_overlay: ColorRect = %HurtOverlay
@onready var damage_indicator: Control = %DamageIndicator

# world_dir points from the player toward where the hit came from.
func hit_from(world_dir: Vector3) -> void:
	damage_indicator.register_hit(world_dir)

var _last_banner_text := ""
var _banner_age := 0.0
var _last_lives := -1
var _pulse := 0.0

func _process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer():
		visible = false
		return
	visible = true
	var id := multiplayer.get_unique_id()
	_update_bar(id)
	_update_hurt(delta, id)
	_update_score()
	_update_banner(delta)

func _update_bar(id: int) -> void:
	var playing := MatchManager.state != MatchManager.State.WAITING and MatchManager.lives.has(id)
	bottom_bar.visible = playing
	if not playing:
		return
	_update_lives(MatchManager.lives[id])
	_update_stamina()

func _update_stamina() -> void:
	var player := _local_player()
	if player == null:
		stamina_bar.visible = false
		return
	stamina_bar.visible = true
	stamina_bar.value = player.stamina
	var low := player.stamina <= Player.MAX_STAMINA * 0.3
	stamina_bar.self_modulate = Color(1, 0.55, 0.25) if low else Color.WHITE

func _local_player() -> Player:
	for p in get_tree().get_nodes_in_group("players"):
		if p is Player and p.is_multiplayer_authority():
			return p
	return null

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

# Fill or clear a slot for a future item/ability. Pass null to empty it.
func set_slot(index: int, texture: Texture2D) -> void:
	if index < 0 or index >= slots_box.get_child_count():
		return
	var icon := slots_box.get_child(index).get_node("Icon") as TextureRect
	icon.texture = texture
	icon.visible = texture != null

func _update_hurt(delta: float, id: int) -> void:
	var n: int = MatchManager.lives.get(id, -1)
	if _last_lives >= 0 and n >= 0 and n < _last_lives:
		_pulse = 1.0
	_last_lives = n
	_pulse = max(0.0, _pulse - delta / PULSE_DECAY)
	var intensity := 0.0
	if MatchManager.state != MatchManager.State.WAITING and n > 0:
		var denom: int = max(1, MatchManager.STARTING_LIVES - 1)
		intensity = clamp(float(MatchManager.STARTING_LIVES - n) / float(denom), 0.0, 1.0) * RAMP_MAX
	hurt_overlay.material.set_shader_parameter("intensity", intensity)
	hurt_overlay.material.set_shader_parameter("pulse", _pulse)

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
