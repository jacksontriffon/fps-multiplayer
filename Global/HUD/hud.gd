extends CanvasLayer

# Reads mirrored MatchManager state plus the lobby podium each frame; never writes.
# The bottom bar holds lives (left) and the 3 inventory slots (right). Each slot
# mirrors the local player's held ball for that slot, and the active slot (picked
# with the 1/2/3 keys) is highlighted.

const TEAM_NAMES := ["Red", "Blue"]
const BANNER_HOLD := 2.5
const PULSE_DECAY := 0.6
const RAMP_MAX := 0.25
const HEART_FULL := preload("res://Assets/Textures/UI/heart_full.svg")
# Bar pixels per stamina point (visual scale only — gameplay numbers are unchanged). The bar
# and each heart cell use the same scale, so a heart cell is exactly as wide as the stamina it
# reserves and the fill lines up flush with the hearts.
const STAMINA_PX_PER_UNIT := 2.0
const HEART_WIDTH := Player.STAMINA_PER_HEART * STAMINA_PX_PER_UNIT
const BALL_ICON := preload("res://Assets/Textures/UI/dodgeball.svg")
const PREVIEW_SIZE := Vector2i(96, 96)
const PREVIEW_SPIN := 0.9  # radians/sec for the slow item turntable

@onready var bottom_bar: HBoxContainer = %BottomBar
@onready var stamina_panel: Panel = %StaminaBar
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

# Kept as the last child of the Lives box; shown only for the infinite-hearts effect.
var _infinity_label: Label

# Slot panel styles: the active slot gets a brighter border so it reads as selected.
var _slot_normal: StyleBoxFlat
var _slot_active: StyleBoxFlat

# One isolated 3D preview rig per slot (see _build_previews). _slot_keys tracks what
# each slot currently shows so the 3D model is only rebuilt when the item changes.
var _preview_viewports: Array[SubViewport] = []
var _preview_pivots: Array[Node3D] = []
var _preview_cams: Array[Camera3D] = []
var _preview_active: Array[bool] = []
var _slot_keys: Array[String] = []

func _ready() -> void:
	_slot_normal = slots_box.get_child(0).get_theme_stylebox("panel")
	_slot_active = _slot_normal.duplicate()
	_slot_active.border_color = Color(1, 1, 1, 0.9)
	_slot_active.bg_color = Color(0, 0, 0, 0.65)
	_infinity_label = Label.new()
	_infinity_label.text = "∞"
	_infinity_label.add_theme_font_size_override("font_size", 26)
	_infinity_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_infinity_label.visible = false
	lives_box.add_child(_infinity_label)
	stamina_panel.custom_minimum_size.x = Player.TOTAL_STAMINA * STAMINA_PX_PER_UNIT
	_build_previews()

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
	# Slowly turn the live item previews so they read as 3D.
	for i in _preview_active.size():
		if _preview_active[i]:
			_preview_pivots[i].rotate_y(delta * PREVIEW_SPIN)

func _update_bar(id: int) -> void:
	var player := _local_player()
	var infinite := player != null and player.has_effect(Player.INFINITE_HEARTS)
	# Show the bar during a match, or whenever the local player carries the
	# infinite-hearts effect (e.g. standing in the lobby zone).
	var playing := MatchManager.state != MatchManager.State.WAITING and MatchManager.lives.has(id)
	var show := playing or infinite
	bottom_bar.visible = show
	if not show:
		for i in _preview_viewports.size():
			_disable_preview(i)
		return
	# Eliminated (elimination modes only): swap the whole bar for the ELIMINATED label.
	var eliminated: bool = not infinite \
		and MatchManager.game_mode != Pedestal.GameMode.CAPTURE_THE_FLAG \
		and int(MatchManager.lives.get(id, 0)) <= 0
	if eliminated:
		stamina_panel.visible = false
		lives_text.visible = true
		lives_text.text = "ELIMINATED"
		lives_text.modulate = Color(1, 1, 1, 0.7)
		_update_slots(id)
		return
	stamina_panel.visible = true
	lives_text.visible = false
	if infinite:
		_update_lives_infinite()
	# Lives/hearts are a Team-mode concept; CTF has no elimination, so it shows no hearts —
	# the bar is then pure stamina, which still applies (you throw in CTF too).
	elif MatchManager.game_mode == Pedestal.GameMode.CAPTURE_THE_FLAG:
		_ensure_hearts(0)
		_infinity_label.visible = false
	else:
		_update_lives(MatchManager.lives[id])
	_update_stamina()
	_update_slots(id)

func _update_stamina() -> void:
	var player := _local_player()
	if player == null:
		stamina_bar.visible = false
		return
	stamina_bar.visible = true
	# The bar's max is the usable pool left after hearts/debuffs take their slice, so its
	# pixel width (it expands to fill what the heart cells don't) maps 1:1 to stamina.
	var cap := player.stamina_capacity()
	stamina_bar.max_value = maxf(cap, 1.0)
	stamina_bar.value = player.stamina
	var low := cap > 0.0 and player.stamina <= cap * 0.3
	stamina_bar.self_modulate = Color(1, 0.55, 0.25) if low else Color.WHITE

func _local_player() -> Player:
	for p in get_tree().get_nodes_in_group("players"):
		if p is Player and p.is_multiplayer_authority():
			return p
	return null

func _update_lives(n: int) -> void:
	# Each heart cell is a current life and claims its slice of the bar; losing a heart drops
	# its cell entirely, which is what widens the stamina region. No empty hearts here.
	_infinity_label.visible = false
	_ensure_hearts(n)
	for heart in _heart_rects():
		heart.texture = HEART_FULL

# A single full heart followed by an ∞ sign — the infinite-hearts effect.
func _update_lives_infinite() -> void:
	_ensure_hearts(1)
	_heart_rects()[0].texture = HEART_FULL
	lives_box.move_child(_infinity_label, lives_box.get_child_count() - 1)  # keep ∞ at the far right
	_infinity_label.visible = true

# Heart icons are the TextureRect children of the Lives box; the ∞ label also lives
# there but is excluded so it never gets treated as (or freed like) a heart.
func _heart_rects() -> Array:
	var hearts := []
	for child in lives_box.get_children():
		if child is TextureRect:
			hearts.append(child)
	return hearts

func _ensure_hearts(count: int) -> void:
	var hearts := _heart_rects()
	while hearts.size() < count:
		var heart := TextureRect.new()
		heart.custom_minimum_size = Vector2(HEART_WIDTH, 0)
		heart.size_flags_vertical = Control.SIZE_FILL
		heart.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		heart.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		lives_box.add_child(heart)
		lives_box.move_child(heart, lives_box.get_child_count() - 2)  # hearts sit right of the fill, before ∞
		hearts.append(heart)
	while hearts.size() > count:
		hearts.pop_back().free()

# Mirror the local player's inventory: each occupied slot shows its item (a live 3D
# preview by default, or the item's flat item_ui texture when it has one) and the
# active slot is highlighted. Held balls carry the holder's peer id and slot index.
func _update_slots(id: int) -> void:
	var player := get_tree().current_scene.get_node_or_null(str(id)) as Player
	var active: int = player.active_slot if player else 0
	for i in slots_box.get_child_count():
		var slot := slots_box.get_child(i) as Panel
		var icon := slot.get_node("Icon") as TextureRect
		var ball := _ball_in_slot(id, i)
		if ball == null:
			_show_empty(i, icon)
		elif ball.item_ui != null:
			_show_flat(i, icon, ball.item_ui)
		else:
			_show_preview(i, icon, ball)
		slot.add_theme_stylebox_override("panel", _slot_active if i == active else _slot_normal)

func _ball_in_slot(peer_id: int, slot: int) -> Grabbable:
	for b in get_tree().get_nodes_in_group("grabbable"):
		if b is Grabbable and b.held_by == peer_id and b.held_slot == slot:
			return b
	return null

func _show_empty(i: int, icon: TextureRect) -> void:
	icon.visible = false
	icon.texture = null
	_disable_preview(i)
	_slot_keys[i] = ""

func _show_flat(i: int, icon: TextureRect, tex: Texture2D) -> void:
	icon.texture = tex
	icon.visible = true
	_disable_preview(i)
	_slot_keys[i] = "flat"

# Renders the item's 3D model live in the slot's viewport. The model is rebuilt only
# when the item type changes, so the turntable keeps spinning between frames.
func _show_preview(i: int, icon: TextureRect, ball: Grabbable) -> void:
	var key := ball.scene_file_path
	if _slot_keys[i] != key:
		var visual := ball.get_preview_visual()
		if visual == null:
			_show_flat(i, icon, BALL_ICON)  # item has no model — fall back to a flat icon
			return
		_mount_preview(i, visual)
		_slot_keys[i] = key
	icon.texture = _preview_viewports[i].get_texture()
	icon.visible = true
	_preview_active[i] = true
	_preview_viewports[i].render_target_update_mode = SubViewport.UPDATE_ALWAYS

# Builds one off-screen 3D viewport per slot: own world, a framing camera, key+fill
# lights, and a pivot the item mounts under. The viewport's texture feeds the slot Icon.
func _build_previews() -> void:
	for _i in slots_box.get_child_count():
		var sv := SubViewport.new()
		sv.size = PREVIEW_SIZE
		sv.transparent_bg = true
		sv.own_world_3d = true
		sv.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var cam := Camera3D.new()
		cam.fov = 35.0
		cam.current = true
		sv.add_child(cam)
		var key_light := DirectionalLight3D.new()
		key_light.rotation_degrees = Vector3(-40, -30, 0)
		key_light.light_energy = 1.2
		sv.add_child(key_light)
		var fill_light := DirectionalLight3D.new()
		fill_light.rotation_degrees = Vector3(-10, 140, 0)
		fill_light.light_energy = 0.5
		sv.add_child(fill_light)
		var pivot := Node3D.new()
		sv.add_child(pivot)
		add_child(sv)
		_preview_viewports.append(sv)
		_preview_cams.append(cam)
		_preview_pivots.append(pivot)
		_preview_active.append(false)
		_slot_keys.append("")

# Centers the item under the pivot and pulls the camera back to frame its bounds.
func _mount_preview(i: int, visual: Node3D) -> void:
	var pivot := _preview_pivots[i]
	for child in pivot.get_children():
		child.queue_free()
	pivot.add_child(visual)
	var bounds := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	if visual is VisualInstance3D:
		bounds = (visual as VisualInstance3D).get_aabb()
	visual.position = -bounds.get_center()
	var radius: float = maxf(bounds.size.length() * 0.5, 0.1)
	var cam := _preview_cams[i]
	var dist: float = radius / sin(deg_to_rad(cam.fov * 0.5)) * 1.05
	cam.position = Vector3(0, radius * 0.4, dist)
	cam.look_at(Vector3.ZERO, Vector3.UP)

func _disable_preview(i: int) -> void:
	_preview_active[i] = false
	_preview_viewports[i].render_target_update_mode = SubViewport.UPDATE_DISABLED

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
	# Battle royale has no team score — show how many players are still in.
	if MatchManager.game_mode == Pedestal.GameMode.BATTLE_ROYALE:
		var alive_n := 0
		for v in MatchManager.lives.values():
			if v > 0:
				alive_n += 1
		score_label.text = "%d remaining" % alive_n
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
