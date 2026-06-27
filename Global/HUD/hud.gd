extends CanvasLayer

# Reads mirrored MatchManager state plus the lobby podium each frame; never writes.
# The bottom bar holds the lives + stamina bar, centered along the bottom edge.

const TEAM_NAMES := ["Red", "Blue"]
const BANNER_HOLD := 2.5
const PULSE_DECAY := 0.6
const RAMP_MAX := 0.25
const HEART_FULL := preload("res://Assets/Textures/UI/heart_full.svg")
# Bar pixels per stamina point (visual scale only — gameplay numbers are unchanged). The bar
# and each heart cell use the same scale, so a heart cell is exactly as wide as the stamina it
# reserves and the fill lines up flush with the hearts.
const STAMINA_PX_PER_UNIT := 3.0
const HEART_WIDTH := Stamina.PER_HEART * STAMINA_PX_PER_UNIT
# Gold, matching the infinite-ammo orb, for the buff's cell in the stamina bar.
const COLORS_AMMO := Color(1.0, 0.82, 0.2)
# Green, matching the triple-throw orb, for that buff's cell in the stamina bar.
const COLORS_TRIPLE := Color(0.3, 0.9, 0.45)

@onready var bottom_bar: HBoxContainer = %BottomBar
@onready var stamina_panel: Panel = %StaminaBar
@onready var lives_box: HBoxContainer = %Lives
@onready var lives_text: Label = %LivesText
@onready var stamina_bar: ProgressBar = %Stamina
@onready var score_label: Label = %Score
@onready var banner_label: Label = %Banner
@onready var hurt_overlay: ColorRect = %HurtOverlay
@onready var damage_indicator: Control = %DamageIndicator
@onready var spectate_text: Label = %SpectateText
@onready var interact_prompt: VBoxContainer = %InteractPrompt
@onready var interact_name: Label = %Name
@onready var interact_action: Label = %Action

# world_dir points from the player toward where the hit came from.
func hit_from(world_dir: Vector3) -> void:
	damage_indicator.register_hit(world_dir)

# Crosshair interaction prompt, driven by the local player's Hands: the targeted object's
# name on top, the bound key plus the action verb under it (e.g. "Rope" / "(LMB) grab").
func show_interact_prompt(obj_name: String, input_action: StringName, verb: String) -> void:
	interact_name.text = obj_name
	interact_action.text = "(%s) %s" % [_key_label(input_action), verb]
	interact_prompt.visible = true

func hide_interact_prompt() -> void:
	interact_prompt.visible = false

# Top-of-screen banner shown while the local player is in creative map-building mode, listing the
# controls. Driven by the player's Creative controller on toggle.
func set_creative(active: bool) -> void:
	if _creative_label:
		_creative_label.visible = active

func _build_creative_label() -> void:
	_creative_label = Label.new()
	_creative_label.visible = false
	_creative_label.text = "CREATIVE MODE   ·   Double-Space: fly   ·   LMB: grab/hold   ·   RMB + mouse: rotate   ·   Wheel: distance   ·   F2: exit"
	_creative_label.add_theme_font_size_override("font_size", 18)
	_creative_label.add_theme_color_override("font_color", Color(0.6, 0.9, 1.0))
	add_child(_creative_label)
	_creative_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE)
	_creative_label.position.y += 14

# Human-readable label for an action's first bound key/button (mouse buttons take priority
# so the common "(LMB)" wins over a joypad axis also mapped to the same action).
func _key_label(action: StringName) -> String:
	var fallback := "?"
	for ev in InputMap.action_get_events(action):
		if ev is InputEventMouseButton:
			match ev.button_index:
				MOUSE_BUTTON_LEFT: return "LMB"
				MOUSE_BUTTON_RIGHT: return "RMB"
				MOUSE_BUTTON_MIDDLE: return "MMB"
				_: return "Mouse %d" % ev.button_index
		elif ev is InputEventKey and fallback == "?":
			fallback = OS.get_keycode_string(ev.physical_keycode if ev.physical_keycode != 0 else ev.keycode)
	return fallback

var _creative_label: Label
var _last_banner_text := ""
var _banner_age := 0.0
var _last_lives := -1
var _pulse := 0.0

# Kept as the last child of the Lives box; shown only for the infinite-hearts effect.
var _infinity_label: Label

# Gold container slice in the stamina bar for the infinite-ammo buff. Sized to the stamina
# it currently reserves, so it's widest on pickup and shrinks to nothing as the buff expires.
var _ammo_cell: Panel
var _ammo_style: StyleBoxFlat

# Green container slice in the stamina bar for the triple-throw buff, sized to its
# reservation the same way the ammo cell is.
var _triple_cell: Panel
var _triple_style: StyleBoxFlat

# Ability container cells in the stamina bar, one per unlockable movement ability. Each
# is a coloured slice sized to the ability's cost (so it lines up with the stamina the
# bar reserves for it), bright when armed and dim when there isn't enough to fire it.
# Hidden with zero width until an AbilityOrb grants the ability.
var _ability_defs: Array = []
var _ability_cells: Array[Panel] = []
var _ability_styles: Array[StyleBoxFlat] = []

func _ready() -> void:
	_infinity_label = Label.new()
	_infinity_label.text = "∞"
	_infinity_label.add_theme_font_size_override("font_size", 26)
	_infinity_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_infinity_label.visible = false
	lives_box.add_child(_infinity_label)
	stamina_panel.custom_minimum_size.x = Stamina.MAX * STAMINA_PX_PER_UNIT
	_build_ability_cells()
	_build_ammo_cell()
	_build_triple_cell()
	_build_creative_label()

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
	_update_spectate()

func _update_bar(id: int) -> void:
	var player := _local_player()
	var infinite := player != null and player.has_effect(Player.INFINITE_HEARTS)
	var infinite_ammo := player != null and player.has_effect(Player.INFINITE_AMMO)
	var triple := player != null and player.has_effect(Player.TRIPLE_THROW)
	# Show the bar during a match, or whenever the local player carries a lobby buff
	# (infinite hearts in the zone, or the infinite-ammo / triple-throw pickup) so its slots/timer read.
	var playing := MatchManager.state != MatchManager.State.WAITING and MatchManager.lives.has(id)
	var show := playing or infinite or infinite_ammo or triple
	bottom_bar.visible = show
	if not show:
		return
	# Eliminated (elimination modes only, mid-match): swap the whole bar for the ELIMINATED label.
	var eliminated: bool = playing and not infinite \
		and MatchManager.game_mode != Pedestal.GameMode.CAPTURE_THE_FLAG \
		and int(MatchManager.lives.get(id, 0)) <= 0
	if eliminated:
		stamina_panel.visible = false
		lives_text.visible = true
		lives_text.text = "ELIMINATED"
		lives_text.modulate = Color(1, 1, 1, 0.7)
		return
	stamina_panel.visible = true
	lives_text.visible = false
	if infinite:
		_update_lives_infinite()
	elif MatchManager.lives.has(id):
		_update_lives(MatchManager.lives[id])
	else:
		_update_lives(0)  # buff shown outside a match — no hearts to draw
	_update_stamina()

func _update_stamina() -> void:
	var player := _local_player()
	_update_ability_cells(player)
	_update_ammo_cell(player)
	_update_triple_cell(player)
	if player == null:
		stamina_bar.visible = false
		return
	stamina_bar.visible = true
	# The bar's max is the usable pool left after hearts/debuffs take their slice, so its
	# pixel width (it expands to fill what the heart cells don't) maps 1:1 to stamina.
	var cap := player.stamina.capacity()
	stamina_bar.max_value = maxf(cap, 1.0)
	stamina_bar.value = player.stamina.amount
	var low := cap > 0.0 and player.stamina.amount <= cap * 0.3
	stamina_bar.self_modulate = Color(1, 0.55, 0.25) if low else Color.WHITE

# One container cell per unlockable ability, inserted just after the stamina fill so the
# order reads [fill][dash][double jump][hearts][∞]. The fill (which expands) shrinks by
# each owned ability's reserved slice, so the cells slot in flush with no width math here.
func _build_ability_cells() -> void:
	_ability_defs = [
		{"effect": Player.ABILITY_DASH, "cost": Dash.DASH_COST, "glyph": "»", "color": Color(0.25, 0.7, 1.0)},
		{"effect": Player.ABILITY_DOUBLE_JUMP, "cost": DoubleJump.DOUBLE_JUMP_COST, "glyph": "↟", "color": Color(0.75, 0.45, 1.0), "stacks": true},
		{"effect": Player.ABILITY_BOMB, "cost": Stamina.BOMB_COST, "glyph": "✸", "color": Color(1.0, 0.45, 0.1)},
	]
	for i in _ability_defs.size():
		var style := StyleBoxFlat.new()
		style.corner_radius_top_left = 3
		style.corner_radius_top_right = 3
		style.corner_radius_bottom_right = 3
		style.corner_radius_bottom_left = 3
		var cell := Panel.new()
		cell.custom_minimum_size = Vector2(0, 0)
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.visible = false
		cell.add_theme_stylebox_override("panel", style)
		var label := Label.new()
		label.text = _ability_defs[i].glyph
		label.set_anchors_preset(Control.PRESET_FULL_RECT)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_font_size_override("font_size", 15)
		cell.add_child(label)
		lives_box.add_child(cell)
		lives_box.move_child(cell, 1 + i)  # right after the stamina fill (child 0)
		_ability_cells.append(cell)
		_ability_styles.append(style)

func _update_ability_cells(player: Player) -> void:
	for i in _ability_defs.size():
		var cell := _ability_cells[i]
		var owned := player != null and player.has_effect(_ability_defs[i].effect)
		if not owned:
			cell.visible = false
			cell.custom_minimum_size.x = 0.0
			continue
		var cost: float = _ability_defs[i].cost
		var color: Color = _ability_defs[i].color
		# Stackable abilities (double jump) own one slice per pickup; the cell widens to match
		# the reserved stamina and the glyph shows the multiplier once you hold more than one.
		var count: int = player.effect_count(_ability_defs[i].effect) if _ability_defs[i].get("stacks", false) else 1
		var armed: bool = player.stamina.amount >= cost
		cell.visible = true
		cell.custom_minimum_size.x = cost * float(count) * STAMINA_PX_PER_UNIT
		_ability_styles[i].bg_color = color if armed else Color(color.r, color.g, color.b, 0.3)
		var label := cell.get_child(0) as Label
		label.text = "%s×%d" % [_ability_defs[i].glyph, count] if count > 1 else _ability_defs[i].glyph
		label.modulate = Color.WHITE if armed else Color(1, 1, 1, 0.5)

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

# A gold ∞ slice in the stamina bar, built like the ability cells and dropped in right after
# the fill so it lines up flush with the stamina it reserves.
func _build_ammo_cell() -> void:
	_ammo_style = StyleBoxFlat.new()
	_ammo_style.corner_radius_top_left = 3
	_ammo_style.corner_radius_top_right = 3
	_ammo_style.corner_radius_bottom_right = 3
	_ammo_style.corner_radius_bottom_left = 3
	_ammo_style.bg_color = COLORS_AMMO
	_ammo_cell = Panel.new()
	_ammo_cell.custom_minimum_size = Vector2(0, 0)
	_ammo_cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ammo_cell.visible = false
	_ammo_cell.add_theme_stylebox_override("panel", _ammo_style)
	var label := Label.new()
	label.text = "∞"
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 18)
	_ammo_cell.add_child(label)
	lives_box.add_child(_ammo_cell)
	lives_box.move_child(_ammo_cell, 1)  # right after the stamina fill (child 0)

# Size the cell to the stamina the buff currently reserves, so it shrinks as the buff expires.
func _update_ammo_cell(player: Player) -> void:
	var amount := player.stamina.reserved(Stamina.RES_INFINITE_AMMO) if player else 0.0
	_ammo_cell.visible = amount > 0.0
	_ammo_cell.custom_minimum_size.x = amount * STAMINA_PX_PER_UNIT

# A green ×3 slice in the stamina bar for the triple-throw buff, built and sized like the
# ammo cell so it shrinks as the buff runs down.
func _build_triple_cell() -> void:
	_triple_style = StyleBoxFlat.new()
	_triple_style.corner_radius_top_left = 3
	_triple_style.corner_radius_top_right = 3
	_triple_style.corner_radius_bottom_right = 3
	_triple_style.corner_radius_bottom_left = 3
	_triple_style.bg_color = COLORS_TRIPLE
	_triple_cell = Panel.new()
	_triple_cell.custom_minimum_size = Vector2(0, 0)
	_triple_cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_triple_cell.visible = false
	_triple_cell.add_theme_stylebox_override("panel", _triple_style)
	var label := Label.new()
	label.text = "×3"
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 16)
	_triple_cell.add_child(label)
	lives_box.add_child(_triple_cell)
	lives_box.move_child(_triple_cell, 1)  # right after the stamina fill (child 0)

func _update_triple_cell(player: Player) -> void:
	var amount := player.stamina.reserved(Stamina.RES_TRIPLE_THROW) if player else 0.0
	_triple_cell.visible = amount > 0.0
	_triple_cell.custom_minimum_size.x = amount * STAMINA_PX_PER_UNIT

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
	# Battle royale and race have no team score — show how many players are still in.
	if MatchManager.game_mode == Pedestal.GameMode.BATTLE_ROYALE \
			or MatchManager.game_mode == Pedestal.GameMode.RACE:
		var alive_n := 0
		for v in MatchManager.lives.values():
			if v > 0:
				alive_n += 1
		var noun := "racing" if MatchManager.game_mode == Pedestal.GameMode.RACE else "remaining"
		score_label.text = "%d %s" % [alive_n, noun]
		return
	var r: int = MatchManager.team_scores[0]
	var b: int = MatchManager.team_scores[1]
	var text := "%s  %d  —  %d  %s" % [TEAM_NAMES[0], r, b, TEAM_NAMES[1]]
	# In a Classic tournament, append the maps-won series tally above the per-map round score.
	if MatchManager.is_tournament:
		text += "    (Series %d–%d)" % [MatchManager.tournament_wins[0], MatchManager.tournament_wins[1]]
	score_label.text = text

# Death cam / spectator status, sourced from the local player's own spectator state.
func _update_spectate() -> void:
	var player := _local_player()
	spectate_text.text = player.spectate_text if player else ""

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
