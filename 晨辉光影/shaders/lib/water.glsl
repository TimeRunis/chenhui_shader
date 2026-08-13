// ================= 晨辉光影 · 水面 =================
// 注意：本文件被 #include 使用，不写 #version；选项宏由顶层 .fsh
// 定义后 include（#if 在 lib 中合法——include 时宏已定义）
//
// 波纹风格二选一（WATER_WAVE_STYLE 选项，GUI 可切换）：
// 0 = Derivative 4 层 noise2 风格（旧版：小碎波 + 距离衰减）
// 1 = SEUS-Renewed GetWaves 6 层 noisetex 风格（新版：宽波 + 波峰
//     亮脊 + 高度折入；2026-08-14 用户调整为密度 /40、速度 0.45）
// 光斑（waterCausticsSEUS）两种风格共用（SEUS CalculateWaterCaustics
// 物理折射追算，波纹法线由当前风格提供）

uniform sampler2D noisetex;

// SEUS AlmostIdentity：削掉低于 m 的值（脊线波峰保底）
float almostIdentity(float x, float m, float n) {
	if (x > m) return x;
	float a = 2.0 * n - m;
	float b = 2.0 * m - 3.0 * n;
	float t = x / m;
	return (a * t + b) * t * t + n;
}

// 波浪高度场（风格由 WATER_WAVE_STYLE 选择）：
// position = 世界坐标（SEUS 版含高度折入）；wavesTime = 时间
#if WATER_WAVE_STYLE == 1
// SEUS GetWaves 完整移植（noisetex 版）：
// 6 层（权重 1/4.1/17.25/15.25/29.25/15.25）层间频率递进 + p.x
// 方向扭曲 + 各自速度；末两层 abs 折叠 + AlmostIdentity 削波 =
// 波峰亮脊。2026-08-14 用户调整（两次减半）：密度 /80（SEUS 原
// /20）、速度 0.225（SEUS 原 0.9）
float waterHeightField(vec3 position, float wavesTime) {
	float speed = 0.225;
	vec2 p = position.xz / 80.0;
	p.xy -= position.y / 20.0; // SEUS 高度折入（水面高低处波纹相位不同）
	p.x = -p.x; // SEUS 镜像
	p.x += (wavesTime / 40.0) * speed;
	p.y -= (wavesTime / 40.0) * speed;
	float allwaves = 0.0;
	const float wSum = 82.1; // 1 + 4.1 + 17.25 + 15.25 + 29.25 + 15.25
	// 层 1（宽波，w=1）
	allwaves += texture2D(noisetex, (p * vec2(2.0, 1.2)) + vec2(0.0, p.x * 2.1)).x;
	p /= 2.1; p.y -= (wavesTime / 20.0) * speed; p.x -= (wavesTime / 30.0) * speed;
	// 层 2（w=4.1，反向扭曲）
	allwaves += 4.1 * texture2D(noisetex, (p * vec2(2.0, 1.4)) + vec2(0.0, -p.x * 2.1)).x;
	p /= 1.5; p.x += (wavesTime / 20.0) * speed;
	// 层 3（w=17.25）
	allwaves += 17.25 * texture2D(noisetex, (p * vec2(1.0, 0.75)) + vec2(0.0, p.x * 1.1)).x;
	p /= 1.5; p.x -= (wavesTime / 55.0) * speed;
	// 层 4（w=15.25）
	allwaves += 15.25 * texture2D(noisetex, (p * vec2(1.0, 0.75)) + vec2(0.0, -p.x * 1.7)).x;
	p /= 1.9; p.x += (wavesTime / 155.0) * speed;
	// 层 5（w=29.25，脊线：abs 折叠 + 削波 = 波峰亮脊）
	float w5 = abs(texture2D(noisetex, (p * vec2(1.0, 0.8)) + vec2(0.0, -p.x * 1.7)).x * 2.0 - 1.0);
	allwaves += 29.25 * (1.0 - almostIdentity(w5, 0.2, 0.1));
	p /= 2.0; p.x += (wavesTime / 155.0) * speed;
	// 层 6（w=15.25，反向脊线）
	float w6 = abs(texture2D(noisetex, (p * vec2(1.0, 0.8)) + vec2(0.0, p.x * 1.7)).x * 2.0 - 1.0);
	allwaves += 15.25 * (1.0 - almostIdentity(w6, 0.2, 0.1));
	return allwaves / wSum;
}
#else
// Derivative WaterHeight 参数移植（noise2 版，旧风格）：
// 4 层（频率 0.8/1.6/2.4/3.6、权重 1/0.5/0.2/0.1）+ 对角滚动 +
// 各向异性 p.y×0.8；wavesTime = frameTimeCounter×1.2（2026-08-13
// 用户降速 2.4 → 1.2）
float waterHeightField(vec3 position, float wavesTime) {
	vec2 p2 = position.xz;
	p2.y *= 0.8;
	float wave = 0.0;
	wave += noise2((p2 + vec2(0.0, p2.x - wavesTime)) * 0.8);
	wave += noise2((p2 - vec2(-wavesTime, p2.x)) * 1.6) * 0.5;
	wave += noise2((p2 + vec2(wavesTime * 0.6, p2.x - wavesTime)) * 2.4) * 0.2;
	wave += noise2((p2 - vec2(wavesTime * 0.6, p2.x - wavesTime)) * 3.6) * 0.1;
	return wave;
}
#endif

// 世界空间水面法线（y 向上），amp 为振幅（由 波浪强度 选项驱动）
#if WATER_WAVE_STYLE == 1
// SEUS GetWavesNormal 完整移植：sampleDistance=13（差分间距 0.13 格）
// 三点差分 + 梯度系数 1.154（20×WAVE_HEIGHT(0.75)/sampleDistance）；
// 时间 wavesTime = frameTimeCounter（无倍率）；无距离衰减（SEUS
// 注释掉：波纹低频 10~20 格，远水面不闪烁）。
// amp/0.35 相对缩放：WAVE_AMOUNT=100 时 = SEUS 原梯度，默认 50 减半
vec3 waterNormalWorld(vec3 p, float amp) {
	float wavesTime = frameTimeCounter;
	const float sampleDistance = 13.0;
	vec3 pos = p - vec3(0.005, 0.0, 0.005) * sampleDistance;
	float hC = waterHeightField(pos, wavesTime);
	float hX = waterHeightField(pos + vec3(0.01 * sampleDistance, 0.0, 0.0), wavesTime);
	float hZ = waterHeightField(pos + vec3(0.0, 0.0, 0.01 * sampleDistance), wavesTime);
	vec3 n = vec3((hC - hX) * (amp / 0.35) * 1.154, 1.0, (hC - hZ) * (amp / 0.35) * 1.154);
	// 距离衰减（2026-08-14 用户反馈"远处波纹混杂像噪点"后加回，
	// Derivative 同款；SEUS 原版无——其高频层远处屏幕投影 <1 像素
	// 混叠闪烁）：屏幕导数驱动的波纹收缩——远处 1 像素投影的 xz
	// 格数大 → 衰减强，近处无影响。法线衰减后折射扰动/波光/光斑
	// 全部同步弱化，远处水面平滑
	n.xy /= 0.8 + dot(abs(dFdx(pos.xz) + dFdy(pos.xz)), vec2(80.0 / far));
	return normalize(n);
}
#else
// Derivative GetWavesNormal 移植（旧风格）：0.04 差分步长 + 0.7 垂直
// 分量（倾角收缓）+ 距离衰减（远水面波纹收缩防闪烁）
vec3 waterNormalWorld(vec3 p, float amp) {
	float wavesTime = frameTimeCounter * 1.2;
	vec2 p2 = p.xz;
	p2.y *= 0.8;
	float hC = waterHeightField(vec3(p2.x, 0.0, p2.y), wavesTime);
	float hX = waterHeightField(vec3(p2.x + 0.04, 0.0, p2.y), wavesTime);
	float hZ = waterHeightField(vec3(p2.x, 0.0, p2.y + 0.04), wavesTime);
	vec3 n = normalize(vec3((hC - hX) * amp, 0.7, (hC - hZ) * amp));
	// 距离衰减（Derivative 同款）：远水面波纹收缩，防强波纹在
	// 远处产生闪烁/锯齿
	n.xy /= 0.8 + dot(abs(dFdx(p2) + dFdy(p2)), vec2(80.0 / far));
	return normalize(n);
}
#endif

// SEUS-Renewed CalculateWaterCaustics 移植（2026-08-14）：
// 光从水面（固定 y=63 海平面近似，SEUS 同款）经波浪法线折射，
// 3×3 入口点追算光打到水底的碰撞点，与当前像素距离 <0.15 格 →
// 聚焦亮斑 pow²×3（波面聚焦/散焦的物理 caustics）。
// 2026-08-14 去逐像素 dither：SEUS 原版用屏幕坐标哈希 dither
//（CalculateNoisePattern1）靠 TAA 掩盖，晨辉前向管线无跨帧时间域
//（记忆硬限制）——dither 让相邻像素采样位置跳变 = caustics 屏幕
// 噪点（"水面大量噪点"根因，两种波纹风格都有）。改固定格中心
// 偏移（+0.5）：相邻像素采样同网格 → caustics 连续无噪；网格感
// 由波浪法线的不规则性打散。返回值 0~3（HDR 量级，调用方缩放）
float waterCausticsSEUS(vec3 worldPos, float amp) {
	float waterPlaneHeight = 63.0; // SEUS 固定海平面近似
	vec3 lightV = sunDirW();
	float vertical = min(abs(worldPos.y - waterPlaneHeight), 2.0);
	vec3 flatRefract = refract(lightV, vec3(0.0, 1.0, 0.0), 1.0 / 1.3333);
	float toWaterLen = vertical / -flatRefract.y;
	vec3 lookupCenter = worldPos - flatRefract * toWaterLen;
	const float distTh = 0.15;
	float caustics = 0.0;
	for (int i = -1; i <= 1; i++) {
		for (int j = -1; j <= 1; j++) {
			vec2 off = (vec2(float(i), float(j)) + 0.5) * 0.2;
			vec3 lp = lookupCenter + vec3(off.x, 0.0, off.y);
			vec3 wn = waterNormalWorld(lp, amp);
			vec3 rv = refract(lightV, wn, 1.0 / 1.3333);
			float rayLen = vertical / rv.y;
			vec3 hit = lp - rv * rayLen;
			float dist = dot(hit - worldPos, hit - worldPos) * 7.1;
			caustics += 1.0 - clamp(dist / distTh, 0.0, 1.0);
		}
	}
	caustics /= 9.0;
	caustics /= distTh;
	return pow(clamp(caustics, 0.0, 1.0), 2.0) * 3.0;
}
