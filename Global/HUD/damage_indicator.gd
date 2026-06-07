extends Control

# COD-style directional damage arcs. A hit stores the world-space direction it came
# from (player -> source); each frame that's re-projected against the local camera's
# yaw into a screen angle, so the arc stays pinned to the source as you turn. Arcs
# fade out over LIFETIME. Fed by HUD.hit_from(), called on the struck authority peer.

const LIFETIME := 1.2
const RADIUS := 130.0
const THICKNESS := 6.0
const SPAN := deg_to_rad(55.0)
const SEGMENTS := 14
const COLOR := Color(1.0, 0.15, 0.15)
# Small triangle on the arc's midpoint, pointing outward away from screen center.
const TRI_HEIGHT := 12.0
const TRI_HALF_WIDTH := 7.0

# Each hit: { dir: Vector3 (horizontal, normalized), age: float, angle: float }.
var _hits: Array = []

func register_hit(world_dir: Vector3) -> void:
	var d := world_dir
	d.y = 0.0
	if d.length() < 0.01:
		return
	_hits.append({ "dir": d.normalized(), "age": 0.0, "angle": 0.0 })
	queue_redraw()

func _process(delta: float) -> void:
	if _hits.is_empty():
		return
	var cam := _local_camera()
	var live: Array = []
	for hit in _hits:
		hit.age += delta
		if hit.age >= LIFETIME:
			continue
		if cam:
			hit.angle = _screen_angle(cam, hit.dir)
		live.append(hit)
	_hits = live
	queue_redraw()

func _draw() -> void:
	var center := size / 2.0
	for hit in _hits:
		var life: float = 1.0 - hit.age / LIFETIME
		if life <= 0.0:
			continue
		var col := COLOR
		col.a = life
		var a0: float = hit.angle - SPAN * 0.5
		var a1: float = hit.angle + SPAN * 0.5
		var pts := PackedVector2Array()
		for i in SEGMENTS + 1:
			var a: float = lerpf(a0, a1, float(i) / SEGMENTS)
			pts.append(center + Vector2(sin(a), -cos(a)) * (RADIUS + THICKNESS))
		for i in SEGMENTS + 1:
			var a: float = lerpf(a1, a0, float(i) / SEGMENTS)
			pts.append(center + Vector2(sin(a), -cos(a)) * RADIUS)
		draw_colored_polygon(pts, col)
		# Triangle on the arc midpoint, tip aimed outward away from the screen center.
		var out := Vector2(sin(hit.angle), -cos(hit.angle))
		var tan := Vector2(cos(hit.angle), sin(hit.angle))
		var base := RADIUS + THICKNESS
		var tri := PackedVector2Array([
			center + out * (base + TRI_HEIGHT),
			center + out * base + tan * TRI_HALF_WIDTH,
			center + out * base - tan * TRI_HALF_WIDTH,
		])
		draw_colored_polygon(tri, col)

func _local_camera() -> Camera3D:
	if not multiplayer.has_multiplayer_peer():
		return null
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var p := scene.get_node_or_null(str(multiplayer.get_unique_id()))
	if p == null:
		return null
	return p.get_node_or_null("Head/Camera3D") as Camera3D

# Signed angle (radians) of dir relative to where the camera faces: 0 = source dead
# ahead (top of screen), +ve clockwise toward the right, ±PI = directly behind.
func _screen_angle(cam: Camera3D, dir: Vector3) -> float:
	var b := cam.global_transform.basis
	var fwd := -b.z
	fwd.y = 0.0
	if fwd.length() < 0.001:
		# Looking near-vertically: fall back to the head's facing.
		fwd = -b.y
		fwd.y = 0.0
	var right := b.x
	right.y = 0.0
	return atan2(dir.dot(right.normalized()), dir.dot(fwd.normalized()))
