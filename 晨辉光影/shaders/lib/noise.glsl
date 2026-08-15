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

// 3D 标量 hash（真 3D 值噪声角点用）
float hash13(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453123);
}

// 真 3D 值噪声：8 角点三线性插值（高质量体积云 CLOUDS=3 用）。
// 与 noise2(x+z, y+z) 的伪 3D 切片不同：三个轴频率真正独立，
// 云团在垂直方向可以自由起伏，不会被拉成水平层带。
float noise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);
	float n000 = hash13(i);
	float n100 = hash13(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash13(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash13(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash13(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash13(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash13(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash13(i + vec3(1.0, 1.0, 1.0));
	return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
	           mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

// 真 3D 分形噪声（高质量体积云用，连续频率 LOD 版）。
// 每 octave 按其特征周期随采样步长 dt 连续淡出（fade），替代
// 整数 LOD 切换——整数切换的边界在屏幕上是以视线方向为心的
// 同心圆伪影（档位越高圆圈越大）。fade 区间 = 0.30~0.55×特征
// 周期：dt 接近该层周期时权重平滑归零，防混叠且无图案跳变。
// 返回值已按有效权重和归一化（均值≈0.5），各 dt 下浓度一致。
float fbm3d(vec3 p, float dt) {
	float v = 0.0;
	float amp = 0.5;
	float sumW = 0.0;
	float period = 2500.0;   // oct0 水平特征周期（格），×2.31 递进
	for (int i = 0; i < 4; i++) {
		float fade = 1.0 - smoothstep(period * 0.30, period * 0.55, dt);
		float w = amp * fade;
		v += w * noise3(p);
		sumW += w;
		p = p * 2.31 + vec3(13.7, 29.3, 7.9);
		amp *= 0.5;
		period /= 2.31;
	}
	return v / max(sumW, 1e-4);
}
