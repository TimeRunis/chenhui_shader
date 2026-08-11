// ================= 晨辉光影 · 水面 =================
// 注意：本文件被 #include 使用，不写 #version

// 世界空间水面法线（y 向上），amp 为振幅（由 波浪强度 选项驱动）
// 波纹密度对齐 Derivative Main（lib/Water/WaterWave.glsl）：4 层
// 噪声频率 0.8/1.6/2.4/3.6 → 波长 1.25/0.63/0.42/0.28 格（旧版
// 0.18/0.55 = 5.6/1.8 格，密度提升 ~4.5 倍、单个波纹面积大幅减小）。
// 权重按 Derivative 比例（1/0.5/0.2/0.1）归一化到与原版相同的总
// 梯度（0.5），WAVE_AMOUNT 振幅语义不变。差分步长按各层波长 ~4%
// （同 Derivative 的 0.04/主波长 1.25）。时间系数按频率同比，波纹
// 移动速度 ≈1 格/秒（比旧版略快，波纹更灵动）
vec3 waterNormalWorld(vec3 p, float amp) {
	float t = frameTimeCounter * 0.5;
	vec2 q1 = p.xz * 0.8 + vec2(t * 0.8, t * 1.0);
	vec2 q2 = p.xz * 1.6 - vec2(t * 1.6, 0.0);
	vec2 q3 = p.xz * 2.4 + vec2(t * 1.9, t * 1.0);
	vec2 q4 = p.xz * 3.6 - vec2(t * 2.9, 0.0);
	float e1 = 0.05, e2 = 0.03, e3 = 0.02, e4 = 0.015;
	float dx = (noise2(q1 + vec2(e1, 0.0)) - noise2(q1 - vec2(e1, 0.0))) * 0.22
	         + (noise2(q2 + vec2(e2, 0.0)) - noise2(q2 - vec2(e2, 0.0))) * 0.14
	         + (noise2(q3 + vec2(e3, 0.0)) - noise2(q3 - vec2(e3, 0.0))) * 0.09
	         + (noise2(q4 + vec2(e4, 0.0)) - noise2(q4 - vec2(e4, 0.0))) * 0.05;
	float dz = (noise2(q1 + vec2(0.0, e1)) - noise2(q1 - vec2(0.0, e1))) * 0.22
	         + (noise2(q2 + vec2(0.0, e2)) - noise2(q2 - vec2(0.0, e2))) * 0.14
	         + (noise2(q3 + vec2(0.0, e3)) - noise2(q3 - vec2(0.0, e3))) * 0.09
	         + (noise2(q4 + vec2(0.0, e4)) - noise2(q4 - vec2(0.0, e4))) * 0.05;
	vec3 n = normalize(vec3(-dx * amp, 1.0, -dz * amp));
	return n;
}
