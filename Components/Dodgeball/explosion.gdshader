shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled;

// Both driven per-explosion from explosive.gd.
instance uniform float progress : hint_range(0.0, 1.0) = 0.0;
instance uniform float blast_radius = 6.0;

uniform vec4 core_color : source_color = vec4(1.0, 0.75, 0.3, 1.0);
uniform vec4 rim_color : source_color = vec4(1.0, 0.2, 0.05, 1.0);

void vertex() {
	// Unit sphere inflated out to the blast radius, fast at first then easing off.
	float eased = 1.0 - pow(1.0 - progress, 3.0);
	VERTEX *= mix(0.2, blast_radius, eased);
}

void fragment() {
	float fres = pow(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 2.0);
	float fade = pow(1.0 - progress, 1.5);
	ALBEDO = mix(core_color.rgb, rim_color.rgb, fres);
	ALPHA = clamp(fres * 1.2 + 0.15, 0.0, 1.0) * fade;
}
