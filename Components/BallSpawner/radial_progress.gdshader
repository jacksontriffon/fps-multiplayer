shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_mix;

// Per-instance so many spawners share one material but fill independently.
instance uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec4 fill_color : source_color = vec4(0.3, 0.9, 0.4, 0.5);
uniform vec4 track_color : source_color = vec4(0.05, 0.28, 0.12, 0.65);
uniform float inner_radius : hint_range(0.0, 1.0) = 0.55;
uniform float outer_radius : hint_range(0.0, 1.0) = 0.96;
// Shift in the camera plane (right, up) so the bar rides the ball's top-right corner.
uniform vec2 view_offset = vec2(0.22, 0.22);

void vertex() {
	// Billboard: keep the node's world position but face the camera, then nudge the
	// whole quad along the view's right/up axes so it sits at the ball's top-right.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	VERTEX.xy += view_offset;
}

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float r = length(p);
	if (r < inner_radius || r > outer_radius) {
		discard;
	}
	// Angle from the top, sweeping clockwise, mapped to 0..1.
	float ang = atan(p.x, -p.y);
	float frac = ang < 0.0 ? (ang + TAU) / TAU : ang / TAU;
	bool filled = frac <= progress;
	ALBEDO = filled ? fill_color.rgb : track_color.rgb;
	ALPHA = filled ? fill_color.a : track_color.a;
}
