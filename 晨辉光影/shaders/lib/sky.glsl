// ================= 晨辉光影 · 程序化天空 =================
// 注意：本文件被 #include 使用，不写 #version；不使用选项宏（强度由调用方传入参数）

float CLOUD_BASE = 205.0;   // 云层底（1.18+ 世界高度 384）
float CLOUD_TOP = 222.0;    // 云层顶

// ===== 维度检测（无 dimension uniform，用固定雾色判定） =====
// 末地雾色 ≈ (0.082, 0.0625, 0.0664) 暗紫；下界雾色 ≈ (0.302, 0.09, 0.09) 暗红
// 主世界昼夜/天气雾色均不满足这两个特征（夜间雾偏蓝且极暗）
int detectDimension() {
	float fr = fogColor.r;
	float fg = fogColor.g;
	float fb = fogColor.b;
	if (fr > 0.13 && fr > fg * 2.5) return -1;                       // 下界
	if (fr > 0.05 && fr < 0.12 && fr > fg * 1.25 && fr > fb) return 1;  // 末地
	return 0;                                                        // 主世界
}

// ===== 星光 =====
// density01: 密度系数 0~1（1.0 = 默认密度 1/16，每 16 格约 1 颗星，网格 100/弧度）
// moonDiscR: 月亮角半径（末地无月亮传 0）；太阳角半径固定按 100% 计
vec3 starField(vec3 dir, float strength, float density01, float moonDiscR) {
	if (dir.y < 0.02 || strength <= 0.001 || density01 <= 0.001) return vec3(0.0);
	// 网格 300 → 100/弧度：格内半径 0.36 不变，星角直径正好为原来的 3 倍，
	// 且星星仍完整落在格内（圆形不被裁剪）；星数 300²/18 vs 100²/16 = 1/8
	vec3 p = dir * 100.0;
	vec3 c = floor(p);
	vec3 f = fract(p);
	vec3 rnd = hash3(c);
	// 密度：默认 1/16（每 16 个格子约 1 颗星），由 STAR_DENSITY 缩放
	if (hash1(dot(c, vec3(3.7, 9.1, 5.3))) > density01 / 16.0) return vec3(0.0);
	float d2 = distance(f, rnd);
	float s = smoothstep(0.36, 0.0, d2);    // 星半径 0.36 格（网格 100 → 直径约为原 3 倍）
	if (s < 0.01) return vec3(0.0);
	// 避开日月盘面：盘内完全隐藏星星，向外 0.04 rad 淡入（世界空间角距）
	float angMoon = acos(clamp(dot(dir, moonDirW()), -1.0, 1.0));
	float angSun = acos(clamp(dot(dir, sunDirW()), -1.0, 1.0));
	float rDisc = moonDiscR + 0.012;
	float mask = smoothstep(rDisc, rDisc + 0.04, min(angMoon, angSun));
	float tw = 0.55 + 0.45 * hash1(floor(frameTimeCounter * 5.0) + dot(c, vec3(12.3, 45.6, 78.9)));
	return vec3(0.85, 0.9, 1.0) * s * tw * strength * mask;
}

// ===== 云（2D 高度场 + 垂直形状） =====
float cloudDensity(vec2 xz, float y) {
	vec2 uv = xz * 0.0011 + vec2(frameTimeCounter * 0.006, 0.0);
	float cov = fbm2(uv, 3);
	cov = smoothstep(0.45, 0.62, cov);
	float shape = smoothstep(0.0, 0.35, (y - CLOUD_BASE) / 17.0)
	            * (1.0 - smoothstep(0.65, 1.0, (y - CLOUD_BASE) / 17.0));
	float detail = 0.55 + 0.45 * fbm2(uv * 2.7 + vec2(0.0, y * 0.05), 2);
	return cov * shape * detail;
}

// 云光照
vec3 cloudShade(float dens, float df, float wet) {
	vec3 sd = sunDirW();
	float lit = clamp(sd.y * 3.0 + 0.35, 0.12, 1.0) * df + (1.0 - df) * 0.1;
	vec3 col = mix(vec3(0.28, 0.32, 0.4), vec3(0.78, 0.83, 0.92), lit);
	col += vec3(1.0, 0.82, 0.62) * lit * df * 0.55;
	col *= 1.0 - wet * 0.5;                 // 雨天云层变暗
	return col;
}

// ===== 月亮：固定满月 + 细节 =====
// 盘面环形山/月海细节为程序生成，不随太阳方向变化（始终满月）
// size: 角半径（由 MOON_SIZE 缩放，1.0 = 0.0566 rad）
vec3 moonDetail(vec3 dir, float size) {
	vec3 md = moonDirW();
	float cosA = dot(dir, md);
	float ang = acos(clamp(cosA, -1.0, 1.0));
	// 泛光：紧致月晕 + 宽柔光晕（伪泛光，双指数衰减；边缘 ~0.13，延伸 ~2 倍月亮半径）
	// 注意：必须最先计算并单独返回——若在盘面裁剪之后算，宽泛光会被 1.6 倍半径的
	// 提前退出截断，导致光晕完全不可见
	vec3 glow = vec3(0.40, 0.45, 0.60) * exp(-ang * 36.0) * 0.9
	          + vec3(0.35, 0.40, 0.55) * exp(-ang * 70.0) * 0.5;
	if (ang > size * 1.6 || size < 0.001) return glow;
	// 边缘抗锯齿：盘内 disc=1，过渡带（≥20% 半径或 3 像素）内 1→0，外沿多留半像素。
	// 注意必须 1-smoothstep：smoothstep 语义是 x>edge1 才=1，直接写会把中心也变 0
	float aa = max(fwidth(ang), 0.00001);
	float disc = 1.0 - smoothstep(size - max(0.20 * size, aa * 3.0), size + aa * 0.5, ang);
	if (disc < 0.01) return glow;
	// 盘面切线坐标：用与盘面垂直的正交基 e1/e2 投影
	// （不能用 perp.xy——月亮挂高时切向 z 分量占主导，图案会塌缩成条纹）
	vec3 perp = dir - md * cosA;
	float r = max(length(perp), 0.0001);
	vec3 e1 = cross(md, vec3(0.0, 1.0, 0.0));
	e1 = (dot(e1, e1) < 0.0001) ? vec3(1.0, 0.0, 0.0) : normalize(e1);   // 天顶退化兜底
	vec3 e2 = normalize(cross(md, e1));
	vec2 dp = vec2(dot(perp, e1), dot(perp, e2)) / r * (ang / max(size, 0.0001));
	// 月海（大块暗斑）
	float maria = 0.40 + 0.60 * smoothstep(0.52, 0.30, fbm2(dp * 1.8 + vec2(3.1, 7.7), 2));
	// 环形山（中高频斑驳）
	float crater = 0.62 + 0.38 * fbm2(dp * 6.5 + vec2(1.3, 9.9), 3);
	vec3 moonCol = vec3(0.52, 0.52, 0.57) * maria * crater;
	// 固定满月：细节不随太阳方向变化（不做月相）
	return moonCol * 1.15 + glow;
}

// ===== 太阳：细节盘面（世界空间，视角转动时固定） =====
// 米粒组织（表面颗粒）+ 太阳黑子 + 临边昏暗 + 中心白到边缘暖黄的色温渐变
// size: 角半径（由 SUN_SIZE 缩放，1.0 = 0.0566 rad）
vec3 sunDetail(vec3 dir, float size) {
	vec3 sd = sunDirW();
	float cosA = dot(dir, sd);
	float ang = acos(clamp(cosA, -1.0, 1.0));
	if (ang > size * 1.6 || size < 0.001) return vec3(0.0);
	// 边缘抗锯齿：盘内 disc=1，过渡带（≥20% 半径或 3 像素）内 1→0，外沿多留半像素。
	// 注意必须 1-smoothstep：smoothstep 语义是 x>edge1 才=1，直接写会把中心也变 0
	float aa = max(fwidth(ang), 0.00001);
	float disc = 1.0 - smoothstep(size - max(0.20 * size, aa * 3.0), size + aa * 0.5, ang);
	if (disc < 0.01) return vec3(0.0);
	// 盘面切线坐标（与月亮同套正交基投影，避免挂高时塌缩）
	vec3 perp = dir - sd * cosA;
	float r = max(length(perp), 0.0001);
	vec3 e1 = cross(sd, vec3(0.0, 1.0, 0.0));
	e1 = (dot(e1, e1) < 0.0001) ? vec3(1.0, 0.0, 0.0) : normalize(e1);
	vec3 e2 = normalize(cross(sd, e1));
	vec2 dp = vec2(dot(perp, e1), dot(perp, e2)) / r * (ang / max(size, 0.0001));
	// 米粒组织（中高频颗粒，微调亮度起伏）
	float gran = 0.45 + 0.55 * fbm2(dp * 12.0 + vec2(4.7, 1.2), 3);
	// 太阳黑子（低频暗斑，避开边缘）
	float spotN = 1.0 - smoothstep(0.55, 0.30, fbm2(dp * 2.2 + vec2(8.3, 5.5), 2));
	float spots = spotN * smoothstep(0.80, 0.45, length(dp)) * 0.55;
	// 临边昏暗 + 色温：中心亮白 → 边缘暗暖
	float limb = 1.0 - 0.28 * smoothstep(0.0, 1.0, ang / size);
	// 边缘压暗：外层 40% 把亮度压到剪裁线（1.0）以下。原峰值 6.0 时盘内全被
	// 钳白，可见边缘落在颗粒噪声调制的"亮度=1.0"等值线上，逐像素起伏 → 锯齿毛边；
	// 现在白色核心只到 ~0.85r，其外由平滑的角度渐变控制，边缘不再被噪声切割
	float rim = 1.0 - 0.80 * smoothstep(0.60, 0.95, ang / size);
	vec3 col = mix(vec3(1.0, 0.98, 0.90), vec3(1.0, 0.74, 0.44),
	               0.35 * smoothstep(0.0, 1.0, ang / size));
	float bright = 2.0 * (0.55 + 0.55 * gran) * (1.0 - spots) * limb * rim;
	return col * disc * bright;
}

// ===== 主世界天空 =====
vec3 overworldSky(vec3 dir, float stars, float sunGlow, float sunSize, float moonSize, float starDensity) {
	float df = dayFactorF();
	vec3 sd = sunDirW();                    // 世界空间太阳方向（与 dir 同空间）
	float up = max(dir.y, 0.0);
	// 冷暖色调分离（瑞利散射式）：地平线基础色 = 夜晚深邃冷蓝 → 白天清亮
	// 蓝白（不含浑浊黄灰）；只有太阳真正低角度时（warm 太阳倾斜因子，
	// 正午≈0、深夜门控归零）才叠加橙黄→淡粉的散射暖色
	float sdY = clamp(sd.y, 0.0, 1.0);
	float warm = exp(-sdY * 9.0) * smoothstep(0.10, 0.30, df);
	vec3 warmC = mix(vec3(0.98, 0.55, 0.28), vec3(0.85, 0.42, 0.58), 0.35);
	// 天顶：夜晚深蓝 → 白天清蓝，黄昏微染暖紫（0.20 权重）
	vec3 zenith = mix(vec3(0.015, 0.022, 0.05), vec3(0.24, 0.45, 0.78), df);
	zenith += warmC * warm * 0.20;
	// 地平线：夜晚深邃冷蓝（隐入夜空）→ 白天清亮蓝白
	vec3 horizon = mix(vec3(0.012, 0.02, 0.04), vec3(0.66, 0.75, 0.88), df);
	// 低角度太阳散射：暖色强度 = 太阳倾斜因子（warm），色相橙黄→淡粉
	horizon += warmC * (warm * 0.9);
	vec3 sky = mix(horizon, zenith, pow(up, 0.5));
	sky *= 1.0 - wetness * 0.55;            // 雨天天空变暗
	// 太阳：细节盘面（世界空间，泛光在 composite1 屏幕空间绘制）
	sky += sunDetail(dir, sunSize * 0.0566);
	// 月亮：固定满月 + 细节 + 泛光（世界空间方向，视角转动时固定）
	sky += moonDetail(dir, moonSize * 0.0566);
	// 星光（避开日月盘面；月亮角半径按当前 MOON_SIZE）
	sky += starField(dir, stars * (1.0 - df) * 1.4, starDensity, moonSize * 0.0566);
	return sky;
}

// ===== 末地：黑洞 =====

// 黑洞方向（世界空间固定方向；不能再乘视图矩阵——调用方传入的 dir 已是世界空间）
vec3 blackHoleDir() {
	return normalize(vec3(0.6, 0.75, 0.4));
}

// 引力透镜：靠近视界的背景采样方向被弯向外环（爱因斯坦环）
vec3 lensedDir(vec3 dir) {
	vec3 bh = blackHoleDir();
	float cosBH = dot(dir, bh);
	float r = sqrt(max(1.0 - cosBH * cosBH, 0.0));
	float bend = smoothstep(0.17, 0.0, r);
	if (bend < 0.001) return dir;
	vec3 perp = normalize(dir - bh * cosBH + vec3(0.0001, 0.0, 0.0));
	return normalize(bh + perp * (bend * 0.42 + 0.03));
}

// 黑洞本体（视界 + 光子环 + 倾斜吸积盘 + 辉光）
vec3 blackHole(vec3 dir) {
	vec3 bh = blackHoleDir();
	float cosBH = dot(dir, bh);
	float r = sqrt(max(1.0 - cosBH * cosBH, 0.0));
	vec3 bhCol = vec3(0.0);
	// 光子环（视界边缘的极亮细环）
	float ring = smoothstep(0.99961, 0.99958, cosBH) * smoothstep(0.99930, 0.99942, cosBH);
	bhCol += vec3(1.0, 0.85, 0.65) * ring * 2.0;
	// 吸积盘（倾斜环面，多普勒增亮 + 湍流 + 内热外冷温度色）
	vec3 axis = normalize(vec3(0.4, 0.12, 0.9));
	float z = dot(dir, axis);
	float projR = r / sqrt(max(1.0 - z * z, 0.001));
	float disk = smoothstep(1.5, 0.95, projR) * smoothstep(0.3, 0.6, projR) * step(0.0, z);
	if (disk > 0.005) {
		vec2 ph = normalize(dir - axis * z + vec3(0.0001, 0.0, 0.0)).xy;
		float ang = atan(ph.y, ph.x);
		float dopp = 1.0 + 0.5 * sin(ang * 1.0 + frameTimeCounter * 0.9);
		float turb = 0.55 + 0.45 * fbm2(vec2(ang * 2.5, projR * 12.0) + vec2(frameTimeCounter * 0.5, 0.0), 2);
		vec3 dcol = mix(vec3(1.0, 0.95, 0.9), vec3(0.75, 0.45, 0.2), smoothstep(0.5, 1.4, projR));
		bhCol += dcol * disk * dopp * turb * 2.4;
	}
	// 外层辉光（双指数衰减）
	float glow = exp(-max(r - 0.028, 0.0) * 40.0) + exp(-max(r - 0.028, 0.0) * 10.0) * 0.45;
	bhCol += vec3(0.55, 0.45, 0.4) * glow * 0.30;
	return bhCol;
}

// 末地天空：纯黑 + 星云 + 星（透镜弯曲）+ 黑洞
vec3 endSky(vec3 dir, float stars, float starDensity) {
	vec3 ld = lensedDir(dir);
	vec3 neb = vec3(0.02, 0.012, 0.035)
	         + vec3(0.028, 0.016, 0.055) * fbm3(ld * 2.6 + vec3(frameTimeCounter * 0.004, 0.0, 0.0), 3);
	vec3 col = neb;
	col += starField(ld, stars * 1.2, starDensity, 0.0);   // 末地无月亮
	col += blackHole(dir);
	return col;
}

// ===== 总入口 =====
vec3 getSkyColor(vec3 dir, float stars, float sunGlow, float sunSize, float moonSize, float starDensity) {
	// 实验：强制主世界天空（排查维度检测误判）
	return overworldSky(dir, stars, sunGlow, sunSize, moonSize, starDensity);
}
