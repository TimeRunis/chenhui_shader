// ================= 晨辉光影 · 水面 =================
// 注意：本文件被 #include 使用，不写 #version
//
// 参数完整移植自 Derivative Main（lib/Water/WaterWave.glsl）：
// - 层频率 0.8 / 1.6 / 2.4 / 3.6（波长 1.25 / 0.63 / 0.42 / 0.28 格）
// - 层权重 1.0 / 0.5 / 0.2 / 0.1（Derivative 原值）
// - 高度差分步长 0.04（Derivative 原值，统一不按层缩放）
// - 速度 wavesTime = frameTimeCounter × 1.2（Derivative：1.2 × WATER_WAVE_SPEED）
// - 时间滚动：各层对角滚动（p.x 交叉项，同 Derivative）
// - 各向异性 p.y × 0.8（同 Derivative）
// - 法线垂直分量 0.5（Derivative GetWavesNormal 原值）
// - 距离衰减（Derivative WaterHeight 同款）
// 与 Derivative 的差异：噪声源用本包 noise2 哈希值噪声（Derivative
// 用 256² noisetex 平滑采样），图案纹理不同但尺度/密度/速度一致；
// 高度权重（WATER_WAVE_HEIGHT=1.0）由调用方 amp（WAVE_AMOUNT 选项）承担。

// 波浪高度场（Derivative WaterHeight 参数移植，noise2 版）
float waterHeightField(vec2 p2, float wavesTime) {
	float wave = 0.0;
	wave += noise2((p2 + vec2(0.0, p2.x - wavesTime)) * 0.8);
	wave += noise2((p2 - vec2(-wavesTime, p2.x)) * 1.6) * 0.5;
	wave += noise2((p2 + vec2(wavesTime * 0.6, p2.x - wavesTime)) * 2.4) * 0.2;
	wave += noise2((p2 - vec2(wavesTime * 0.6, p2.x - wavesTime)) * 3.6) * 0.1;
	return wave;
}

// 世界空间水面法线（y 向上），amp 为振幅（由 波浪强度 选项驱动，
// 对应 Derivative WATER_WAVE_HEIGHT）
vec3 waterNormalWorld(vec3 p, float amp) {
	float wavesTime = frameTimeCounter * 1.2; // 波动速率（2026-08-13 用户要求降到 1/2：2.4 → 1.2）
	vec2 p2 = p.xz;
	p2.y *= 0.8;
	// Derivative GetWavesNormal：center/left/up 三点高度差分
	float hC = waterHeightField(p2, wavesTime);
	float hX = waterHeightField(p2 + vec2(0.04, 0.0), wavesTime);
	float hZ = waterHeightField(p2 + vec2(0.0, 0.04), wavesTime);
	vec3 n = normalize(vec3((hC - hX) * amp, 0.7, (hC - hZ) * amp)); // 0.7：倾角收缓，水面明暗斑块平静（0.5 时浅蓝/深蓝膜）
	// 距离衰减（Derivative 同款）：远水面波纹收缩，防强波纹在
	// 远处产生闪烁/锯齿
	n.xy /= 0.8 + dot(abs(dFdx(p2) + dFdy(p2)), vec2(80.0 / far));
	return normalize(n);
}
