// ================= 晨辉光影 · 噪声函数 =================
// 注意：本文件被 #include 使用，不写 #version

float hash1(float n) {
	return fract(sin(n) * 43758.5453123);
}

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

vec3 hash3(vec3 p) {
	return fract(sin(vec3(dot(p, vec3(127.1, 311.7, 74.7)),
	                      dot(p, vec3(269.5, 183.3, 246.1)),
	                      dot(p, vec3(113.5, 271.9, 124.6)))) * 43758.5453123);
}

// 2D 值噪声
float noise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash2(i);
	float b = hash2(i + vec2(1.0, 0.0));
	float c = hash2(i + vec2(0.0, 1.0));
	float d = hash2(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 分形噪声（2D）
float fbm2(vec2 p, int oct) {
	float v = 0.0;
	float amp = 0.5;
	vec2 q = p;
	for (int i = 0; i < oct; i++) {
		v += amp * noise2(q);
		q = q * 2.03 + vec2(17.3, 9.7);
		amp *= 0.5;
	}
	return v;
}

// 分形噪声（3D 近似：用 2D 噪声加高度偏移，性价比高）
float fbm3(vec3 p, int oct) {
	float v = 0.0;
	float amp = 0.5;
	vec3 q = p;
	for (int i = 0; i < oct; i++) {
		v += amp * noise2(q.xy + q.z * 17.31);
		q = q * 2.05 + vec3(13.7, 29.3, 7.9);
		amp *= 0.5;
	}
	return v;
}
