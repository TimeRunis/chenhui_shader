// ================= 晨辉光影 · 程序化天空 =================
// 注意：本文件被 #include 使用，不写 #version；不使用选项宏（强度由调用方传入参数）

// 云层高度/厚度对齐 Derivative Main（altitude 1000、thickness 1400）
float CLOUD_BASE = 1000.0;  // 云层底（高空云）
float CLOUD_TOP = 2400.0;   // 云层顶（厚 1400 格）
// 单位密度每格吸收系数（volCloud 路径积分用）：d=1、步长 58 格时
// 单步透过率 ≈ exp(-0.23)，24 步密云近实心、边缘薄透——体积厚度感
float CLOUD_ABSORB = 0.004;

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

// （旧 cloudDensity() 2D 高度场死代码已删除——实际生效的只有
//  cloudVolumeDensity / cloudVolumeDensityHQ 体积密度模型）
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

// ===== 体积云密度模型（2D 云档专用：恢复最开始的效果） =====
// 即 2026-08 重写前的最初实现：
// ① 大尺度覆盖场 fbm2 2 oct（基频 2e-4，~5000 格周期）
// ② 5 oct noise2(position.xy + position.z) 伪 3D（垂直频率与
//    水平一致，垂直方向无独立起伏 = 2D 层状观感）
// ③ 原垂直高度曲线：×6.6 快速进入 + 顶部淡出 + 线性削减，
//    密度主体呈水平板（用户认可的最初 2D 风格）
// ④ 细噪点来自 93/31 格两层高频 oct 在 117~400 格步长下混叠
//    ——该观感按用户要求保留为 2D 档风格
float cloudVolumeDensity(vec3 p, float cloudDensity, vec3 wind) {
	// 云带分布（localCoverage）：fbm2 2 oct 替代 noisetex；
	// 下限 0.6：任何位置至少有 60% 云带强度
	float localCoverage = fbm2(p.xz * 2e-4 - wind.xz * 2e-3, 2);
	localCoverage = max(clamp(localCoverage * 3.0 + rainStrength - 0.4, 0.0, 1.0) * 0.5 + 0.5, 0.6);
	if (localCoverage < 0.1) return 0.0;
	vec3 position = p * 4e-4 - wind;
	float density = 0.03;
	float weight = 0.5;
	for (int i = 0; i < 5; i++) {
		density += weight * noise2(position.xy + position.z);
		position = position * 3.0 - wind;
		weight *= 0.5;
	}
	density += 0.5 / 3.0 / 5.0;
	if (density < 1e-6) return 0.0;
	density *= localCoverage;
	float normalizedHeight = clamp((p.y - CLOUD_BASE) / (CLOUD_TOP - CLOUD_BASE), 0.0, 1.0);
	float heightAttenuation = clamp(normalizedHeight * 6.6, 0.0, 1.0)
	                         * clamp((1.0 - normalizedHeight) * (2.0 + rainStrength), 0.0, 1.0);
	density *= heightAttenuation * 1.9;
	density -= heightAttenuation * 0.5 + normalizedHeight * 0.25 + 0.05;
	return clamp(density * 3.0 * cloudDensity, 0.0, 1.0);
}

// ===== 体积云密度模型（3D 云档：CLOUDS=2，方案 A） =====
// 与 2D 档（旧模型）的区别：真 3D 值噪声 fbm3d（三轴频率独立）+ 4 oct 细节，
// 垂直基频 1e-3（1000 格）→ 层厚 1400 格内有完整起伏周期，云团
// 在高度方向圆润堆积，边缘为 smoothstep 重映射出的团块轮廓。
// dt：采样步长，fbm3d 内部按特征周期对每 octave 连续 fade——
// 无整数 LOD 切换边界（太阳周围同心圆伪影的根因）
float cloudVolumeDensityHQ(vec3 p, float cloudDensity, vec3 wind, float dt) {
	vec3 q = p - wind;
	// 大尺度覆盖场：3 oct，基频 1e-4（~10000 格，原 2e-4）——
	// 大片云团数量减半、单个云团更大（用户"大片云数量减半"）
	float covN = fbm2(q.xz * 1e-4, 3);
	float coverage = max(smoothstep(0.30, 0.60, covN * 0.9 + rainStrength * 0.4), 0.25);
	// 真 3D 密度场：水平基频 4e-4（2500 格），垂直基频 1e-3（1000 格）
	vec3 w = vec3(q.x * 4e-4, q.z * 4e-4, q.y * 1.0e-3);
	float shape = fbm3d(w, dt);
	// 阈值重映射：低幅高频归零 → 团状，不产生细颗粒
	shape = smoothstep(0.35, 0.65, shape);
	// 积云式垂直曲线：平底 + 圆顶，主体偏下层（经典积云剖面）。
	// 高档加厚：顶部衰减 0.55→0.65，密度平台向上延到 nh≈0.7，
	// 垂直方向更厚实
	float nh = clamp((p.y - CLOUD_BASE) / (CLOUD_TOP - CLOUD_BASE), 0.0, 1.0);
	float heightGradient = smoothstep(0.0, 0.07, nh)
	                     * (1.0 - smoothstep(0.65, 1.00, nh));
	// 倍率 1.1 → 2.8：补偿 CLOUD_DENSITY 减半，并让 3D 云比减半前
	// 更厚（2D 档保持减半后的旧效果不变）
	return clamp(shape * coverage * heightGradient * 2.8 * cloudDensity, 0.0, 1.0);
}

// ===== 3D 体积云（ray-cloud intersection + 路径积分，CLOUDS=2） =====
// 云层是两平行平面（y=CLOUD_BASE ~ y=CLOUD_TOP）之间的世界空间
// 水平带（高空 1000~2400，对齐 Derivative）。视线与两平面交点的
// 参数 t 取 min/max 排序，相机在层下（仰视）、层内（穿层）、层上
// （俯视云海）三种位置统一处理。
// 采样策略（2026-08 重写，3D 档专用）：
// ① 固定 32 步，步长 = 路径/步数；固定 32 次循环上限 + break
// ② 频率 LOD 连续淡出：fbm3d 按每 octave 特征周期随 dt 平滑
//    fade（0.30~0.55×周期）——无整数档切换边界（太阳周围同心圆
//    伪影的根因），地平线方向也不会出现混叠细噪点
// ③ 透射沿路径 Beer-Lambert 积分（替代"平均密度→薄纱"）：平视
//    长路径云变实、仰视短路径云变薄，云有体积厚度而不是层带
// ④ 光照累积：每步 alpha × 当前透射加权，前向散射 + 自阴影保留
// ⑤ 垂直分层用密度加权平均高度（替代"最后采样点"高度），并弱化
//    云底/云顶明暗差——不再沿高度刷出水平条带
// ⑥ 抖动幅度与步长联动（dt×0.3，原固定 30 格对大步长无效）
// cloudDensity：调用方传入 CLOUD_DENSITY/100（0.75 = 减半后基准）
vec3 volCloud3D(vec3 dir, vec3 skyCol, float df, float cloudDensity) {
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
	float dt = (maxT - tNear) / 32.0;
	// 频率 LOD 不取整数档：dt 直接传入 fbm3d，各 octave 按自身
	// 特征周期连续淡出，避免整数切换边界在屏幕上形成同心圆
	float t = tNear;
	float trans = 1.0;  // 沿路径透射（1 = 全透明）
	float lit = 0.0;    // 散射光累积（alpha × 透射加权）
	float litW = 0.0;
	float ty = 0.0;     // 密度加权平均高度（垂直明暗分层用）
	float tyW = 0.0;
	int cnt = 0;
	vec3 sd = sunDirW();
	float sunFwd = max(dot(dir, sd), 0.0);    // 视线-太阳夹角（前向散射）
	// 风位移：worldTimeCounter 在 Iris 1.7.2 不注入值（恒 0）——
	// 改用 frameTimeCounter（每秒 +1，Iris 确定支持）×5：
	// 风速 ≈ 2e-3×5 = 0.01 噪声单元/秒 ≈ 25 格/秒
	vec3 wind = vec3(2e-3, 2e-4, 1e-3) * frameTimeCounter * 5.0;
	for (int i = 0; i < 32; i++) {
		if (t > maxT) break;
		vec3 p = cameraPosition + dir * (t + dt * 0.5);
		// 抖动（防条带）：幅度与步长联动，只抖 xz（垂直不越层）
		p += vec3(hash1(gl_FragCoord.x * 0.7 + gl_FragCoord.y * 1.3) * dt * 0.3, 0.0,
		          hash1(gl_FragCoord.x * 0.7 + gl_FragCoord.y * 1.3 + 7.7) * dt * 0.3);
		float d = cloudVolumeDensityHQ(p, cloudDensity, wind, dt);
		if (d < 1e-4) { t += dt; continue; }   // 稀疏区跳过（省采样）
		// 太阳光照：前向散射（视线朝向太阳的云亮，pow4 加宽到 ±40°）
		// + 自阴影（密云背光侧暗，阈值对齐重映射后的密度）
		float scat = 0.45 + 0.55 * pow(sunFwd, 4.0);
		float selfSh = 1.0 - 0.40 * smoothstep(0.25, 0.80, d);
		// 路径积分：单步 alpha = 1 - exp(-密度 × 吸收系数 × 步长)
		float a = 1.0 - exp(-d * CLOUD_ABSORB * dt);
		float w = a * trans;                   // 本步可见贡献（被前方遮挡）
		lit += w * scat * selfSh;
		litW += w;
		trans *= 1.0 - a;
		float nh = clamp((p.y - CLOUD_BASE) / (CLOUD_TOP - CLOUD_BASE), 0.0, 1.0);
		ty += nh * w;
		tyW += w;
		cnt++;
		t += dt;
	}
	if (cnt == 0) return skyCol;
	float alpha = 1.0 - trans;
	// 平均散射光照 = lit/litW（每可见贡献单位的散射光，0~1）：
	// 朝向太阳的云 avgLit 高 → 亮，背光/密云 → 暗
	float avgLit = (litW > 1e-4) ? lit / litW : 0.0;
	float tyAvg = (tyW > 1e-4) ? ty / tyW : 0.5;
	vec3 ccol = cloudShade(clamp(avgLit, 0.0, 1.0), df, rainStrength);
	// 垂直明暗分层弱化：云底微暗、云顶微亮，不刷水平条带
	ccol = mix(ccol * 0.85, ccol, smoothstep(0.10, 0.60, tyAvg));
	return mix(skyCol, ccol, clamp(alpha, 0.0, 1.0));
}

// ===== 2D 体积云（恢复最开始的效果，CLOUDS=1） =====
// 密度模型：5 oct noise2(x+z, y+z) 伪 3D + 原高度曲线（层状板）。
// 采样：固定 16 步（原中档默认）、步长上限 400 格、平均密度透射、
// 最后采样点高度分层——即 2026-08 重写前的最初观感（层状质感
// 与细噪点均为用户认可并保留的 2D 档风格）。
vec3 volCloud2D(vec3 dir, vec3 skyCol, float df, float cloudDensity) {
	// 纯平视：交点趋近无穷，云带退化为地平线细线，省略采样
	if (abs(dir.y) < 0.001) return skyCol;
	float camY = cameraPosition.y;
	float tA = (CLOUD_BASE - camY) / dir.y;   // 与层底平面交点
	float tB = (CLOUD_TOP - camY) / dir.y;    // 与层顶平面交点
	float tNear = min(tA, tB);
	float tFar = max(tA, tB);
	if (tFar <= 0.0) return skyCol;           // 云层完全在身后
	tNear = max(tNear, 0.0);                  // 相机在层内：从相机起
	float maxT = min(tFar, 20000.0);
	if (tNear >= maxT) return skyCol;
	// 固定 16 步（原中档默认），步长上限 400 格（最初实现原样）
	int maxSteps = 16;
	float dt = min((maxT - tNear) / float(maxSteps), 400.0);
	float t = tNear;
	float dens = 0.0;   // 密度累积（几何密度）
	float lit = 0.0;    // 散射光累积（密度 × 前向散射 × 自阴影）
	float ty = 0.0;     // 最后采样点垂直高度（末尾垂直分层用）
	int cnt = 0;
	vec3 sd = sunDirW();
	float sunFwd = max(dot(dir, sd), 0.0);    // 视线-太阳夹角（前向散射）
	vec3 wind = vec3(2e-3, 2e-4, 1e-3) * frameTimeCounter * 5.0;
	for (int i = 0; i < 16; i++) {
		if (t > maxT) break;
		vec3 p = cameraPosition + dir * (t + dt * 0.5);
		// 固定 30 格抖动（最初实现原样），只抖 xz
		p += vec3(hash1(gl_FragCoord.x * 0.7 + gl_FragCoord.y * 1.3) * 30.0, 0.0,
		          hash1(gl_FragCoord.x * 0.7 + gl_FragCoord.y * 1.3 + 7.7) * 30.0);
		float d = cloudVolumeDensity(p, cloudDensity, wind);
		if (d < 1e-4) { t += dt; continue; }   // 稀疏区跳过（省采样）
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
	// 平均密度透射（最初实现原样）：密云近实心，与路径长度无关
	float trans = 1.0 - exp(-dens * 3.0);
	// 平均散射光照 = lit/dens（每密度单位的散射光，0~1）
	float avgLit = (dens > 0.001) ? lit / dens : 0.0;
	vec3 ccol = cloudShade(clamp(avgLit, 0.0, 1.0), df, rainStrength);
	// 最后采样点高度分层（最初实现原样）：云底暗冷、云顶亮
	ccol = mix(ccol * 0.7, ccol, smoothstep(0.15, 0.5, ty));
	return mix(skyCol, ccol, clamp(trans, 0.0, 1.0));
}

// ===== 体积云入口（两档：1 = 2D 云 / 2 = 3D 云） =====
// cloudLevel：调用方传入 CLOUDS 选项值（0 关 / 1 2D / 2 3D）
// cloudDensity：调用方传入 CLOUD_DENSITY/100（0.75 = 减半后基准）
// ——lib 文件不允许直接用选项宏
vec3 volCloud(vec3 dir, vec3 skyCol, float df, float cloudLevel, float cloudDensity) {
	if (cloudLevel < 0.5) return skyCol;
	if (cloudLevel > 1.5) return volCloud3D(dir, skyCol, df, cloudDensity);
	return volCloud2D(dir, skyCol, df, cloudDensity);
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
