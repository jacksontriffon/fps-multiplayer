extends Node3D
class_name CaptureTheFlag

# Self-contained capture-the-flag area: two bases, a flag and a scoreboard, all under one
# node so you can drop it into any map and move it as a unit in the editor. Scoring is
# server-authoritative; the score is replicated and shown on the in-world scoreboard.
#
# Rule: carry the flag into your OWN team's base to score for your team. Flip
# score_at_own_base to require delivering it to the ENEMY base instead.

@export var score_at_own_base := true
@export var capture_limit := 3

const TEAM_NAMES := ["Red", "Blue"]
const RESET_DELAY := 3.0

@onready var flag: Flag = $Flag
@onready var bases: Array = [$RedBase, $BlueBase]
@onready var scoreboard: Label3D = $Scoreboard

var scores := [0, 0]
# Latched between a capture and the post-capture reset so one delivery scores once.
var _locked := false

func _ready() -> void:
	_refresh_scoreboard()

func _physics_process(_delta: float) -> void:
	# Only the host scores; clients just display the replicated result. (Offline LOCAL
	# play reports is_server() == true, so this runs there too.)
	if not multiplayer.is_server() or _locked:
		return
	if flag == null or flag.held_by == 0:
		return
	var holder := get_tree().current_scene.get_node_or_null(str(flag.held_by)) as Player
	if holder == null:
		return
	for base in bases:
		if base and holder in base.get_overlapping_bodies():
			_try_capture(holder, base)
			return

func _try_capture(holder: Player, base: CTFBase) -> void:
	var scoring_team: int = holder.team
	var allowed := (base.team == scoring_team) if score_at_own_base else (base.team != scoring_team)
	if not allowed:
		return
	scores[scoring_team] += 1
	_locked = true
	flag.server_reset()
	var team_name: String = TEAM_NAMES[scoring_team % TEAM_NAMES.size()]
	var banner := "%s wins!" % team_name if scores[scoring_team] >= capture_limit else "%s scores!" % team_name
	_sync_score.rpc(scores, banner)
	_after_capture()

func _after_capture() -> void:
	await get_tree().create_timer(RESET_DELAY).timeout
	if not multiplayer.is_server():
		return
	if scores[0] >= capture_limit or scores[1] >= capture_limit:
		scores = [0, 0]
	flag.server_reset()
	_locked = false
	_sync_score.rpc(scores, "")

@rpc("authority", "call_local", "reliable")
func _sync_score(s: Array, banner: String) -> void:
	scores = s
	_refresh_scoreboard(banner)

func _refresh_scoreboard(banner := "") -> void:
	if scoreboard == null:
		return
	var line := "%s  %d  -  %d  %s" % [TEAM_NAMES[0], scores[0], scores[1], TEAM_NAMES[1]]
	scoreboard.text = line if banner == "" else "%s\n%s" % [banner, line]
