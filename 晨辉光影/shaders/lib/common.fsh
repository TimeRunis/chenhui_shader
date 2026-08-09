// ================= 晨辉光影 · 公共库（片元） =================
// 注意：本文件被 #include 使用，不写 #version；不使用任何选项宏（选项由各 .fsh 传入参数）

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 shadowProjection;
uniform mat4 shadowModelView;

uniform vec3 cameraPosition;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 fogColor;
uniform float wetness;
uniform float rainStrength;
uniform float frameTimeCounter;
uniform float viewWidth;
uniform float viewHeight;
uniform float aspectRatio;
uniform float near;
uniform float far;
uniform float fogEnd;
uniform int isEyeInWater;
uniform int worldTime;

uniform sampler2D lightmap;
uniform sampler2D shadowtex0;

// 预曝光系数：gbuffers 输出 colortex0（RGBA16F，半浮点，见 composite1 的
// colortex0Format 声明）。16F 精度 ~0.0005，0~1 漫反射与 HDR 高光（萤石
// emission ~1.2）都精确存储，PRE_EXPOSURE 只是数值缩放（可逆无损）——
// composite1 ÷0.62 恢复时纹值原样回来，不再有 RGBA8 时代的量化压平
// （0.564×0.62=0.35 → 8 位只剩 8 个量化级，"圆石材质被光照压住"的根因）
#define PRE_EXPOSURE 0.62

// 环境天光强度：夜晚暗部冷色环境光占比。光照模型要求夜晚
// 「无光区域接近黑色」——环境光只许留极淡蓝紫轮廓，不允许
// 覆盖材质（0.20 → 0.12 → 0.06 → 0.025 逐级下调）
#define AMBIENT_LIGHT_STRENGTH 0.025

// 深度线性化（近裁剪面/远裁剪面）
float linDepth(float d) {
	return (2.0 * near * far) / (far + near - d * (far - near));
}

// 由深度重建眼空间位置
vec3 viewPosFromDepth(float d, vec2 uv) {
	vec4 clip = vec4(uv * 2.0 - 1.0, d * 2.0 - 1.0, 1.0);
	vec4 vp = gbufferProjectionInverse * clip;
	return vp.xyz / vp.w;
}

// 眼空间 -> 世界空间
vec3 worldPosFromView(vec3 vp) {
	return (gbufferModelViewInverse * vec4(vp, 1.0)).xyz + cameraPosition;
}

// 视线方向（眼空间，远平面点方向）
vec3 viewDirAt(vec2 uv) {
	return normalize(viewPosFromDepth(1.0, uv));
}

// 太阳 / 月亮（眼空间方向，用于视空间光照计算）
vec3 sunDirV() { return normalize(sunPosition); }
vec3 moonDirV() { return normalize(moonPosition); }

// 太阳 / 月亮（世界空间方向，用于天空渲染——必须与视线同空间，否则日月随视角乱动）
vec3 sunDirW() {
	return normalize((gbufferModelViewInverse * vec4(sunPosition, 0.0)).xyz);
}
vec3 moonDirW() {
	return normalize((gbufferModelViewInverse * vec4(moonPosition, 0.0)).xyz);
}

// 白天系数：0=深夜 1=白天（世界空间太阳高度，与视角无关；
// 若用眼空间高度，抬头/低头时昼夜判定会跟着变）
float dayFactorF() {
	return clamp(sunDirW().y * 4.0 + 0.2, 0.0, 1.0);
}

// ===== 阴影采样 =====
// 深度约定（与 OptiFine 阴影相机一致）：深度小 = 更靠近太阳；
// 采样深度 + 偏差 < 当前深度 -> 处于阴影中。
// taps: 0=无阴影 1=单采样 2=2x2 PCF
// n: 表面法线（眼空间），用于斜率偏移（slope scale bias）——
// 表面与阳光方向掠射（法线⊥光线）时自阴影误差最大，
// 偏移必须随之增大，否则斜坡/墙面交界出现阴影痤疮（"脏泥巴"边缘）
float shadowSample(vec3 worldPos, vec3 n, int taps) {
	if (taps <= 0) return 1.0;
	vec4 sp = shadowProjection * shadowModelView * vec4(worldPos, 1.0);
	if (sp.w <= 0.0) return 1.0;
	vec3 p = sp.xyz / sp.w * 0.5 + 0.5;
	if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0 || p.z <= 0.0 || p.z >= 1.0) return 1.0;
	// 深度偏移 = 基础 0.0015 + 斜率偏移 0.004×(1-法线·光线)。
	// shadowDistance=96 → 深度 1.0 = 96 方块，0.0015≈0.14 方块、
	// 最大 0.0055≈0.5 方块——阴影边缘紧贴方块与地面交界线。
	// 之前 0.003+0.009 最大 ≈1.15 方块，把阴影从底部"拉"出去一大截
	float slope = 1.0 - clamp(dot(n, sunDirV()), 0.0, 1.0);
	float bias = 0.0015 + 0.004 * slope;
	// 阴影图边缘淡出：UV/深度接近边界时阴影权重平滑降到 0，
	// 消除 shadowDistance 边缘"阴影突然消失"的方形硬切
	vec2 uvFade = smoothstep(0.0, 0.04, p.xy) * smoothstep(1.0, 0.96, p.xy);
	float zFade = smoothstep(1.0, 0.96, p.z);
	float fade = uvFade.x * uvFade.y * zFade;
	float s = 0.0;
	if (taps >= 2) {
		// 3x3 PCF：~0.8 texel@1024（原 1.6，减半）——阴影边缘保持
		// 适度柔化但轮廓清晰锐利，更贴近 MC 硬朗画风且省性能
		float e = 0.0008;
		for (int i = -1; i <= 1; i++) {
			for (int j = -1; j <= 1; j++) {
				float d = texture(shadowtex0, p.xy + vec2(float(i), float(j)) * e).r;
				s += (d + bias > p.z) ? 1.0 : 0.0;
			}
		}
		s *= 1.0 / 9.0;
	} else {
		// 低档（默认 SHADOW_QUALITY=1）也给 2x2 轻 PCF，避免单采样的方块锯齿
		float e = 0.0005;
		float d00 = texture(shadowtex0, p.xy + vec2( e,  e)).r;
		float d10 = texture(shadowtex0, p.xy + vec2(-e,  e)).r;
		float d01 = texture(shadowtex0, p.xy + vec2( e, -e)).r;
		float d11 = texture(shadowtex0, p.xy + vec2(-e, -e)).r;
		s += (d00 + bias > p.z) ? 1.0 : 0.0;
		s += (d10 + bias > p.z) ? 1.0 : 0.0;
		s += (d01 + bias > p.z) ? 1.0 : 0.0;
		s += (d11 + bias > p.z) ? 1.0 : 0.0;
		s *= 0.25;
	}
	return 1.0 - (1.0 - s) * fade;
}

// ===== 前向光照 =====
// albedo: 反照率；n: 眼空间法线；lmUV: 光照图坐标；viewDir: 眼空间视线
// smoothness/metal: PBR 参数；emissive: 自发光；shadowTaps: 阴影采样档位
float blockLevel(vec2 lmUV) {
	return clamp(texture(lightmap, lmUV).b / texture(lightmap, vec2(15.5 / 16.0, 0.5 / 16.0)).b, 0.0, 1.0);
}

// 真实光源方块光（0..1，排除太阳光的干扰）：光照图 Y 坐标 = 天光级数。
// 白天太阳直射会把方块光也顶到 15 级——若不排除，屏幕空间阴影会把整个
// 阳光下的场景互相投射 → 满屏 Shadow Acne 颗粒，且把直射面再压暗一大截
// （"白天灰暗"的另一半原因）。Y > 0.75（天光 12 级以上）视为白昼直射置零；
// 夜晚/洞穴 Y≈0 完整保留；黄昏 8~11 级平滑过渡
float blockSourceLevel(vec2 lmUV) {
	return blockLevel(lmUV) * (1.0 - smoothstep(0.45, 0.75, lmUV.y));
}


vec3 calcLight(vec3 albedo, vec3 n, vec2 lmUV, vec3 viewDir, vec3 worldPos, float smoothness, float metal, float emissive, int shadowTaps) {
	// 方块光照直接采样（移除 10 点平滑核）：
	// 平滑核（±1~2 级平均）会把光源本体拉暗（萤石 face 0.88→0.76，
	// "萤石周围一圈阴影"）并把光斑内部的亮度递减抹平
	// （"光照没有递减、边缘突然下降"）。
	// 原版 lightmap 本身逐级递减（15 级 ≈ 15 格），直接采样与三分屏
	// 中段（用户认可的 albedo×lightmap 观感）完全一致；方块面内由
	// MC 平滑光照（per-vertex lightUV 插值）提供连续渐变。
	// clamp 到格中心范围 [0.5/16, 15.5/16]（0 级格中心即最低）：
	// 洞穴 lmUV=(0,0) 时不会采样到 0 级格之外
	const vec2 lmMin = vec2(0.5 / 16.0);
	const vec2 lmMax = vec2(15.5 / 16.0);
	vec2 lmc = clamp(lmUV, lmMin, lmMax);
	vec3 lm = texture(lightmap, lmc).rgb;
	float skyLm = lm.g;
	float df = dayFactorF();
	vec3 sd = sunDirV();
	// 定向阴影（原始 0=全阴影 1=全亮）：shadowSample 在太阳相机空间做
	// 深度比较，只计算太阳方向上的遮挡——阴影永远有明确方向
	float sh = shadowSample(worldPos, n, shadowTaps);
	float shadowAmt = 1.0 - sh;
	// ===== 光照图正确提取（OptiFine 布局） =====
	// r = max(天光, 方块光) 的显示亮度；g = 天光显示亮度；
	// b = 方块光烘焙值（仅供 blockLevel 归一化，不做亮度）
	// 天光 = g 通道；方块光 = r 通道本体（光源旁 r 就是方块光，
	// 15 级 = 0.94 原版亮度），仅在方块光盖过天光时（r−g 明显）生效——
	// 不减去天光（减了光源本体变暗），白天 r=g 自然归零
	float skyRaw = lm.g;
	// 方块光掩码：r 明显大于 g（方块光盖过天光）才取方块光，
	// 白天/无光源处 r−g≈0 → 掩码 0
	// 阈值 (0.02, 0.06) → (0.003, 0.015)：方块光 1~2 级时 r−g 只有
	// 0.013~0.055，旧阈值把它们归入"天光区"→ 被夜晚衰减 ×0.15，
	// 光斑最外圈（1 级 0.08）从天光（0.067）断崖掉到 0.012——
	// "光源周围一圈深阴影"的根因
	float blockMask = smoothstep(0.003, 0.015, lm.r - lm.g);
	// 天光分量（仅供 ambient 门控 skyVis 使用，不参与漫反射 light）：
	// 白天阴影衰减 + 夜晚衰减——ambient 只在"天光接近零"时关闭，
	// 夜晚无光处保持弱门控（0.12），环境光不覆盖材质
	float sky = skyRaw * (1.0 - 0.4 * shadowAmt * df);
	sky *= mix(1.0, 0.15, 1.0 - df);
	// ===== 照明合成（亮度锚点 = 原版 r 通道，颜色中性） =====
	// 三分屏 debug 定论：① 原版 lightmap 的 r 通道（max 天光/方块光
	// 显示亮度，永不超原版）是正确亮度锚点——纹理比例原样保留；
	// ② lightmap 的 b 通道（方块光烘焙色 0.2~0.5）会把灰色材质
	// 染成暖橙红（用户反馈"圆石覆盖一层光源颜色"），g 通道夜晚
	// 太低导致颜色失真——颜色改由中性白提供，色温交给太阳项/
	// 月光/环境光项各自负责；③ 合成色温（blockC/skyC、烘焙色
	// 收敛）都会把混合光压偏（红色光斑/洗白），不采用。
	// 白天阴影修正（只作用天光主导区）：阴影处天光 ×0.6~1，
	// 火把/萤石旁（r−g 大）系数 = 1 保留原版亮度
	float skyCorr = mix(1.0,
		1.0 - 0.4 * shadowAmt * df,
		1.0 - blockMask);
	// 夜晚低光衰减（r 连续，无阶跃断崖）：r < 0.4（方块光 7 级以下/
	// 天光）时夜晚平滑衰减到 0.3。注意 MC 1.20.1 夜晚天光 = 0.267
	// （月光 1 级，不是 0.067）——旧区间 smoothstep(0.06, 0.12)
	// 在 0.267 处=1 → 天光全量保留 = 原版月光亮度 = "夜视效果"。
	// 现在：天光 0.267→0.10 暗（"夜晚接近黑色"），方块光 6 级
	// 0.33→0.26、7 级 0.4→1 连续过渡——光斑 8 格内全量保留、
	// 外圈平滑淡出，无阶跃断崖（0.15 全砍 = "深阴影圈"）
	float nightK = mix(0.3, 1.0, smoothstep(0.25, 0.4, lm.r));
	vec3 light = vec3(lm.r) * skyCorr * mix(1.0, nightK, 1.0 - df);
	vec3 color = albedo * light;
	// 太阳直射：阴影处完全无直射（硬阴影，亮面/阴影反差清晰）。
	// 强度 0.15（diffuse）：lightmap 天光 15 级（0.94）本身已是
	// 太阳直射亮度（原版沙子受光 0.85 显示）——旧 0.55 叠加在上面
	// 让受光面达 1.1~1.33×albedo，沙子/草被 HDR 压到 1.0 发白
	// （"白天过曝"）。0.15 只补朝阳面的方向层次，不做总量叠加
	float ndl = clamp(dot(n, sd), 0.0, 1.0);
	vec3 sunC = vec3(1.0, 0.92, 0.78) * 0.55;
	color += albedo * vec3(1.0, 0.92, 0.78) * 0.15 * ndl * sh * df * (0.35 + 0.65 * skyLm);
	// 月光
	vec3 md = moonDirV();
	float ndm = clamp(dot(n, md), 0.0, 1.0);
	// 月光（只照到有天空光的地方）：深夜户外天光 1 级 ≈ 0.067 → moonK = 0.335，
	// 月光 0.02×0.335 ≈ 0.007×albedo——极淡的冷色轮廓点缀；
	// 洞穴/室内 skyLm=0 → 归零。0.15→0.07→0.04→0.02 连续下调
	float moonK = clamp(skyLm * 5.0, 0.0, 0.5);
	color += albedo * vec3(0.45, 0.5, 0.75) * 0.02 * ndm * sh * (1.0 - df) * moonK;
	// 环境天光(ambient sky light)：微弱、偏蓝紫、不依赖法线方向的漫反射——
	// 夜晚背光面（树干阴面、地形背光坡）收到极少量天空光。
	// 门控用衰减后的天光 sky：夜晚户外 0.04×12≈0.48 半开、洞穴≈0 关闭、
	// 白天被 (1.0 - df) 关掉——不覆盖材质，只留一丝轮廓
	float skyVis = clamp(sky * 12.0, 0.0, 1.0);
	// 暗部冷色调环境光：AMBIENT_LIGHT_STRENGTH 强度（0.20 基线 + 法线
	// 朝上略亮）——夜晚暗部呈蓝紫氛围，与月光直射面冷暖对比。
	// 阴影区域环境光再衰减 50%：ambient 不覆盖 shadow，
	// 阴影处比普通暗部更暗，投影轮廓清晰
	vec3 ambC = vec3(0.38, 0.42, 0.68) * (AMBIENT_LIGHT_STRENGTH + 0.08 * n.y);
	color += albedo * ambC * skyVis * (1.0 - 0.5 * shadowAmt) * (1.0 - df);
	// 太阳高光（Blinn-Phong）
	// shiny 上限 150、强度 1.1：水面高光更宽更柔——过窄的高光在波浪流动时
	// 亮点满水面乱跳（"光斑随视角变化"的观感），且 1.5 强度会把反射点过曝成白斑
	float shiny = 6.0 + smoothness * smoothness * 150.0;
	vec3 h = normalize(sd + viewDir);
	float ndh = clamp(dot(n, h), 0.0, 1.0);
	vec3 specC = mix(vec3(1.0), albedo, metal * 0.9);
	color += specC * sunC * pow(ndh, shiny) * sh * df * smoothness * 1.1;
	// 自发光（emission）：
	// finalColor = surfaceColor(baseColor×lighting) + emission
	// emission = emissiveMask × baseColor × emissionStrength——
	// 发光色继承纹理（亮区发光强、暗区弱），不会替代材质颜色，
	// 也不会把纹理冲淡成纯色；强度 0.45（0.3~0.6 设计范围）。
	// 原版材质无 specular 贴图（emissive 归零）不受影响
	color += albedo * emissive * 0.45;
	return color;
}
