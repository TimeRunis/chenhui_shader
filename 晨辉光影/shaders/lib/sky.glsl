// ================= 晨辉光影 · 程序化天空 =================
// 注意：本文件被 #include 使用，不写 #version；不使用选项宏（强度由调用方传入参数）

// 云层高度/厚度对齐 Derivative Main（altitude 1000、thickness 1400）
float CLOUD_BASE = 1000.0;  // 云层底（高空云）
float CLOUD_TOP = 2400.0;   // 云层顶（厚 1400 格）

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

// 云光照：把 volCloud 累积的平均散射光照（0~1，含前向散射与自阴影）
// 映射为颜色。旧版签名里的 dens 参数从未被使用（函数体只读太阳高度）
// → 整片云统一亮白，无明暗变化；现在颜色随 avgLit 渐变。
// 基础色：暗部（背光/自阴影）冷蓝灰 → 亮部（迎光）近纯白；
// 再叠加太阳低角度时的黄昏/日出橙黄（warm 太阳倾斜因子，正午≈0）
vec3 cloudShade(float avgLit, float df, float wet) {
	vec3 sd = sunDirW();
	float sdY = clamp(sd.y, 0.0, 1.0);
	float warm = exp(-sdY * 9.0) * smoothstep(0.10, 0.30, df);
	// 昼夜基础：夜晚云暗蓝（月光下 0.06 亮度），白天近纯白
	//（0.92 → 0.97/0.98/1.0：去掉微蓝灰，"云更白"）
	vec3 col = mix(vec3(0.05, 0.07, 0.12), vec3(0.97, 0.98, 1.0), df);
	// 散射光照调制 + 冷暖面：亮部（迎光）近纯白、暗部（背光/自阴影）
	// 冷蓝灰。前向散射（avgLit 太阳方向高）只负责"额外亮"，不再
	// 独占白度——litF 保底 0.45：整片云至少近白，朝向太阳的云更亮
	//（"只有靠近太阳的云白、其他灰"的修复）；暗部下限同时提高
	//（litCol×0.35 → ×0.55），背光云不再是暗灰
	float litF = clamp(0.45 + avgLit * 1.2, 0.0, 1.0);
	vec3 litCol = mix(vec3(0.55, 0.60, 0.70), col, 0.55); // 冷蓝阴影基（提亮）
	col = mix(litCol * 0.55, col, litF);
	// 全天太阳暖调：亮部极淡暖白（0.15 → 0.08：白天云近纯白，
	// 不再带明显暖黄；与"阳光降饱和"一致）
	col += vec3(0.08, 0.06, 0.04) * df * litF;
	// 黄昏/日出橙黄：太阳低角度时云底染橙黄，强度随 warm 呼吸。
	// ×1.3 增强（用户要求傍晚/日出橙黄更明显）；迎光云橙多、
	// 背光云也保留 0.25 基数
	col += vec3(1.0, 0.75, 0.42) * warm * df * (0.25 + 0.75 * avgLit) * 1.3;
	col *= 1.0 - wet * 0.5;                 // 雨天云层变暗
	return col;
}

// ===== 体积云密度模型（移植 Derivative Main lib/Atmosphere/
// VolumetricClouds.glsl CloudVolumeDensity + localCoverage） =====
// 密度形态与 Derivative 一致：
// ① 大尺度覆盖场（~5000 格周期）：云带分布（localCoverage 移植）
// ② 5 oct 3D 噪声密度场（基频 4e-4 = 2500 格周期，×3 递进到 31 格）
// ③ 垂直高度曲线：层内快速进入（×6.6）+ 顶部淡出（×(2+wet)）
//    + 底部削薄（-0.5×normalizedHeight），密度主体偏上层
// wind：世界空间风位移（照搬 Derivative vec3(2e-3,2e-4,1e-3)）
float cloudVolumeDensity(vec3 p, float cloudDensity, vec3 wind) {
	// 云带分布（localCoverage）：fbm2 2 oct 替代 noisetex。
	// 2026-08-13"头顶没云"修复：Derivative 式下限 0.5 + 削减使低带区
	// 密度削到 <0——玩家站在云带空区时头顶（垂直穿过云层）长期无云
	//（wind 25 格/秒 vs 云带特征 5000 格 = 200 秒/周期，移动极慢）。
	// 下限 0.6：任何位置至少有 60% 云带强度（头顶总有云，空区变薄云）
	float localCoverage = fbm2(p.xz * 2e-4 - wind.xz * 2e-3, 2);
	localCoverage = max(clamp(localCoverage * 3.0 + rainStrength - 0.4, 0.0, 1.0) * 0.5 + 0.5, 0.6);
	if (localCoverage < 0.1) return 0.0;
	// 3D 密度场（5 oct ×3 递进；z 直接偏移不放大——Derivative 的
	// 3D 噪声垂直频率与水平一致（特征 2500/3ⁱ 格）。旧 fbm3 风格
	// ×17.31 折叠把垂直频率放大 17.31 倍 → 云层内垂直方向全高频，
	// 采样步长（72~2500 格）垂直分量严重欠采样 → 云沿视线方向被
	// 拉成长条、全部指向日月方向（亮区最显眼）的根因）
	vec3 position = p * 4e-4 - wind;
	float density = 0.03;
	// 各 oct 权重 = Derivative 默认（octWeight 0.5 递进）：
	// 0.5/0.25/0.125/0.0625/0.03125
	float weight = 0.5;
	for (int i = 0; i < 5; i++) {
		density += weight * noise2(position.xy + position.z);
		position = position * 3.0 - wind;
		weight *= 0.5;
	}
	density += 0.5 / 3.0 / 5.0;
	if (density < 1e-6) return 0.0;
	density *= localCoverage;
	// 垂直高度曲线（2026-08-13 削减放宽 0.6/0.3/0.05 → 0.5/0.25/0.05：
	// 头顶/低带区密度不再被削到 <0——配合 localCoverage 下限 0.6，
	// 任何位置头顶都有可见云层）
	float normalizedHeight = clamp((p.y - CLOUD_BASE) / (CLOUD_TOP - CLOUD_BASE), 0.0, 1.0);
	float heightAttenuation = clamp(normalizedHeight * 6.6, 0.0, 1.0)
	                         * clamp((1.0 - normalizedHeight) * (2.0 + rainStrength), 0.0, 1.0);
	density *= heightAttenuation * 1.9;
	density -= heightAttenuation * 0.5 + normalizedHeight * 0.25 + 0.05;
	// 最终倍率 = Derivative 默认 ×3.0（× cloudDensity 选项，
	// CLOUD_DENSITY=150 → 实际 ×4.5）
	return clamp(density * 3.0 * cloudDensity, 0.0, 1.0);
}

// ===== 稳定高度云层（ray-cloud intersection，仅主世界） =====
// 云层是两平行平面（y=CLOUD_BASE ~ y=CLOUD_TOP）之间的世界空间
// 水平带（高空 1000~2400，对齐 Derivative）。视线与两平面交点的
// 参数 t 取 min/max 排序，相机在层下（仰视）、层内（穿层）、层上
// （俯视云海）三种位置统一处理。
// 采样策略（对齐 Derivative）：步长 = 路径/步数（无固定上限——
// 密度场是低频的（基频 2500 格），大步长不欠采样；旧版 10 格上限
// 是为高频 2D 云形设计的，已随密度模型一起移除）。
// 光照：透明度（dens）与散射光（lit）分开累积——透射强度只由
// 几何密度决定，亮度另算前向散射（视线朝向太阳的云亮）与自阴影
// （密云背光侧暗），云团有迎光/背光面。
// 步长起点按像素 hash 抖动（固定幅度 30 格 ≈ 1% 主噪声周期，打散
// 大步长下的采样对齐，防条带）。
// cloudLevel：调用方传入 CLOUDS 选项值（0 关 / 1 低 / 2 中 / 3 高）
// cloudDensity：调用方传入 CLOUD_DENSITY/100（1.0 = 基准，1.5 = 1.5 倍）
// ——lib 文件不允许直接用选项宏
vec3 volCloud(vec3 dir, vec3 skyCol, float df, float cloudLevel, float cloudDensity) {
	if (cloudLevel < 0.5) return skyCol;
	// 纯平视（|dir.y| < 0.001）：交点趋近无穷，云带退化为地平线
	// 细线，省略采样（也避免除零）
	if (abs(dir.y) < 0.001) return skyCol;
	float camY = cameraPosition.y;
	float tA = (CLOUD_BASE - camY) / dir.y;   // 与层底平面交点
	float tB = (CLOUD_TOP - camY) / dir.y;    // 与层顶平面交点
	float tNear = min(tA, tB);
	float tFar = max(tA, tB);
	if (tFar <= 0.0) return skyCol;           // 云层完全在身后
	tNear = max(tNear, 0.0);                  // 相机在层内：从相机起
	// 路径上限 20000 格（对齐 Derivative 的 rayLength clamp 2e4）：
	// 高空云层地平线方向路径更长，上限不足会让地平线云带消失
	float maxT = min(tFar, 20000.0);
	if (tNear >= maxT) return skyCol;
	// 步数提高（低档 8 步 → 12）：地平线方向路径 20000 格时旧步长
	// 2500 格/步严重欠采样 = 云拉成水平层带（"一层一层"的根因）
	int maxSteps = (cloudLevel > 2.5) ? 24 : ((cloudLevel > 1.5) ? 16 : 12);
	// 步长 = 路径/步数，上限 400 格（16% 主噪声周期 2500 格）：
	// 防地平线方向极端大步长；地平线覆盖到 9.6km（透视压缩区内）
	float dt = min((maxT - tNear) / float(maxSteps), 400.0);
	float t = tNear;
	float dens = 0.0;   // 透明度累积（几何密度）
	float lit = 0.0;    // 散射光累积（密度 × 前向散射 × 自阴影）
	float ty = 0.0;     // 垂直归一化高度（循环内更新，末尾垂直分层用）
	int cnt = 0;
	vec3 sd = sunDirW();
	float sunFwd = max(dot(dir, sd), 0.0);    // 视线-太阳夹角（前向散射）
	// 风位移：worldTimeCounter 在 Iris 1.7.2 不注入值（恒 0）——
	// 云完全静止 + 头顶 localCoverage 永远卡在无云值 = "云一直没动、
	// 头顶自始自终没有云"的根因。改用 frameTimeCounter（每秒 +1，
	// Iris 确定支持）×5：风速 ≈ 2e-3×5 = 0.01 噪声单元/秒
	// ≈ 25 格/秒（用户调参：运动速度砍半，原 ×10 = 50 格/秒）
	vec3 wind = vec3(2e-3, 2e-4, 1e-3) * frameTimeCounter * 5.0;
	for (int i = 0; i < maxSteps; i++) {
		if (t > maxT) break;
		vec3 p = cameraPosition + dir * (t + dt * 0.5);
		// 抖动（防条带）：固定幅度 30 格 ≈ 1% 主噪声周期（2500 格），
		// 大步长下也能打散采样对齐；只抖 xz
		p += vec3(hash1(gl_FragCoord.x * 0.7 + gl_FragCoord.y * 1.3) * 30.0, 0.0,
		          hash1(gl_FragCoord.x * 0.7 + gl_FragCoord.y * 1.3 + 7.7) * 30.0);
		// 密度模型（移植 Derivative CloudVolumeDensity）：
		// 覆盖场 + 5 oct 3D 噪声 + 垂直高度曲线（云底削薄）
		float d = cloudVolumeDensity(p, cloudDensity, wind);
		if (d < 1e-4) { t += dt; continue; }   // 稀疏区跳过（省采样）
		// 太阳光照（保留）：前向散射（视线朝向太阳的云亮，pow4 加宽
		// 到 ±40°）+ 自阴影（密云背光侧暗，0.40 弱化不过度发灰）
		float scat = 0.45 + 0.55 * pow(sunFwd, 4.0);
		float selfSh = 1.0 - 0.40 * smoothstep(0.1, 0.55, d);
		dens += d;
		lit += d * scat * selfSh;
		cnt++;
		ty = (p.y - CLOUD_BASE) / (CLOUD_TOP - CLOUD_BASE);
		t += dt;
	}
	if (cnt == 0) return skyCol;
	dens /= float(cnt);
	lit /= float(cnt);
	// 透射（密度已在 cloudVolumeDensity 内部乘 ×3×cloudDensity，
	// 这里不再额外放大）：dens≈0.5 时 trans≈0.78，密云近实心
	float trans = 1.0 - exp(-dens * 3.0);
	// 平均散射光照 = lit/dens（每密度单位的散射光，0~1）：
	// 朝向太阳的云 avgLit 高 → 亮，背光/密云 → 暗
	float avgLit = (dens > 0.001) ? lit / dens : 0.0;
	vec3 ccol = cloudShade(clamp(avgLit, 0.0, 1.0), df, rainStrength);
	// 垂直分层：云底暗冷、云顶亮（ty = 最后采样点归一化高度，
	// 0=层底 1=层顶）——云有上下明暗层次，不是均匀色块
	//（0.6 → 0.7：云底提亮配合"云更白"，层次保留）
	ccol = mix(ccol * 0.7, ccol, smoothstep(0.15, 0.5, ty));
	return mix(skyCol, ccol, clamp(trans, 0.0, 1.0));
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
vec3 overworldSky(vec3 dir, float stars, float sunGlow, float sunSize, float moonSize, float starDensity, float cloudLevel, float cloudDensity) {
	float df = dayFactorF();
	vec3 sd = sunDirW();                    // 世界空间太阳方向（与 dir 同空间）
	float up = max(dir.y, 0.0);
	// 地平线以下（高空俯视渲染距离外的下方天空）：只返回地平线
	// 基础色——日月/星光只画在上半球天空。旧版把完整天空画到
	// 地平线以下 = 高空俯视在"地面以下"看到月亮（"反色月亮"）。
	// 云层例外：云在世界空间高度带内（205~222），相机在云上时
	// 俯视应该看到云海——volCloud 的 ray-cloud intersection 对
	// dir.y < 0 同样成立（tNear/tFar 自动排序），这里照常调用。
	// 雾混合由调用方（composite1 的 hz×0.45）继续叠加
	if (dir.y <= 0.0) {
		vec3 horizonD = mix(vec3(0.012, 0.02, 0.04), vec3(0.66, 0.75, 0.88), df);
		horizonD *= (1.0 - rainStrength * 0.55);
		return volCloud(dir, horizonD, df, cloudLevel, cloudDensity);
	}
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
	sky *= 1.0 - rainStrength * 0.55;       // 雨天天空变暗（跟随降雨强度，雨停即恢复）
	// 太阳：细节盘面（世界空间，泛光在 composite1 屏幕空间绘制）
	sky += sunDetail(dir, sunSize * 0.0566);
	// 月亮：固定满月 + 细节 + 泛光（世界空间方向，视角转动时固定）
	sky += moonDetail(dir, moonSize * 0.0566);
	// 星光（避开日月盘面；月亮角半径按当前 MOON_SIZE）
	sky += starField(dir, stars * (1.0 - df) * 1.4, starDensity, moonSize * 0.0566);
	// 简单体积云（在日月星光之后混合——云浓时遮日/月；
	// cloudLevel=0 时 volCloud 直接返回 skyCol，零开销）
	sky = volCloud(dir, sky, df, cloudLevel, cloudDensity);
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
vec3 getSkyColor(vec3 dir, float stars, float sunGlow, float sunSize, float moonSize, float starDensity, float cloudLevel, float cloudDensity) {
	// 实验：强制主世界天空（排查维度检测误判）
	return overworldSky(dir, stars, sunGlow, sunSize, moonSize, starDensity, cloudLevel, cloudDensity);
}
