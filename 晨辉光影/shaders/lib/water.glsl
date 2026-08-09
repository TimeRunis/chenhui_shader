// ================= 晨辉光影 · 水面 =================
// 注意：本文件被 #include 使用，不写 #version

// 世界空间水面法线（y 向上），amp 为振幅（由 波浪强度 选项驱动）
vec3 waterNormalWorld(vec3 p, float amp) {
	float t = frameTimeCounter * 0.5;
	vec2 q1 = p.xz * 0.11 + vec2(t * 0.13, t * 0.17);
	vec2 q2 = p.xz * 0.33 - vec2(t * 0.21, 0.0);
	float e = 1.4;
	float dx = (noise2(q1 + vec2(e, 0.0)) - noise2(q1 - vec2(e, 0.0))) * 0.325
	         + (noise2(q2 + vec2(e, 0.0)) - noise2(q2 - vec2(e, 0.0))) * 0.175;
	float dz = (noise2(q1 + vec2(0.0, e)) - noise2(q1 - vec2(0.0, e))) * 0.325
	         + (noise2(q2 + vec2(0.0, e)) - noise2(q2 - vec2(0.0, e))) * 0.175;
	vec3 n = normalize(vec3(-dx * amp, 1.0, -dz * amp));
	return n;
}
