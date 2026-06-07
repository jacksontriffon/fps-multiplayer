shader_type canvas_item;

// Red hurt vignette. `intensity` is the steady ramp from lives lost;
// `pulse` is a transient flash added on each hit. Both 0..1.
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;
uniform vec4 hurt_color : source_color = vec4(0.55, 0.0, 0.0, 1.0);

void fragment() {
	float dist = length(UV - vec2(0.5)) * 1.41421356;
	float vig = smoothstep(0.25, 0.95, dist);
	float steady = intensity * vig;
	float flash = pulse * mix(0.5, 1.0, vig);
	float a = clamp(steady + flash, 0.0, 1.0) * hurt_color.a;
	COLOR = vec4(hurt_color.rgb, a);
}
