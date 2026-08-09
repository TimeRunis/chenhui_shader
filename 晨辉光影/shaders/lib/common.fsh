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

// 预曝光系数：gbuffers 输出 colortex0（RGBA8，只能存 0~1）。高光（阳光直射的
// 沙子 ~1.35、萤石自发光 ~3.3）直接写入会被硬截断 → 高光溢出、纹理全白丢失。
// 写入前乘 0.62 把 HDR 压进量化范围保留层次，composite1 末尾 ÷0.62 恢复再 ACES
#define PRE_EXPOSURE 0.62

// 环境天光强度：夜晚暗部冷色环境光占比（0.20 = 暗部有蓝紫氛围，
// 但不会喧宾夺主把阴影反差冲掉）
#define AMBIENT_LIGHT_STRENGTH 0.20

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
	// 方块光照平滑：中心×2 + 十字 ±1.5 级 + 对角 ±2.5 级（10 点加权平均）。
	// 对角权重更大 = 菱形 45° 尖角方向扩散更远 → 方形光斑圆化；
	// 同时消除 16 级光照贴图的阶梯边缘。
	// 所有采样点必须 clamp 到 [0.5/16, 15.5/16]（各级格中心范围，0.5/16 是
	// 0 级格中心）：洞穴内 lmUV=(0,0) 时，未 clamp 的对角偏移 +2.5/16 会落到
	// 2 级方块光格（亮度 0.133），把全黑洞穴抬到 ~0.05×albedo——"封住也亮"、
	// 以及"光源边缘比光源外暗"的根源。clamp 后暗处所有采样点都留在 0 级格，
	// 平滑只把光斑边缘往暗处混，永不把暗处往亮抬
	const vec2 lmA = vec2(1.5 / 16.0);   // 十字（正交方向）偏移
	const vec2 lmD = vec2(2.5 / 16.0);   // 对角（菱形尖角方向）偏移
	const vec2 lmMin = vec2(0.5 / 16.0);
	const vec2 lmMax = vec2(15.5 / 16.0);
	vec2 lmc = clamp(lmUV, lmMin, lmMax);
	vec3 lm = (texture(lightmap, clamp(lmc - vec2(lmA.x, 0.0), lmMin, lmMax)).rgb
	         + texture(lightmap, clamp(lmc + vec2(lmA.x, 0.0), lmMin, lmMax)).rgb
	         + texture(lightmap, clamp(lmc - vec2(0.0, lmA.y), lmMin, lmMax)).rgb
	         + texture(lightmap, clamp(lmc + vec2(0.0, lmA.y), lmMin, lmMax)).rgb
	         + texture(lightmap, clamp(lmc - lmD, lmMin, lmMax)).rgb
	         + texture(lightmap, clamp(lmc + vec2(lmD.x, -lmD.y), lmMin, lmMax)).rgb
	         + texture(lightmap, clamp(lmc + vec2(-lmD.x, lmD.y), lmMin, lmMax)).rgb
	         + texture(lightmap, clamp(lmc + lmD, lmMin, lmMax)).rgb
	         + texture(lightmap, lmc).rgb * 2.0) / 10.0;
	float skyLm = lm.r;
	float df = dayFactorF();
	vec3 sd = sunDirV();
	// 定向阴影（原始 0=全阴影 1=全亮）：shadowSample 在太阳相机空间做
	// 深度比较，只计算太阳方向上的遮挡——阴影永远有明确方向
	float sh = shadowSample(worldPos, n, shadowTaps);
	float shadowAmt = 1.0 - sh;
	// 阴影中的天光衰减（关键）：MC 光照图天空分量 lm.r 在阴影里仍是 100%，
	// 若不衰减，天光会把阴影整个"冲掉"→ 地面阴影不可见。
	// 阴影区域天光降至 60% = 阴影比普通暗部再低 40%。只衰减天空分量
	// （方块光 lm.b 不受阳光遮挡影响）；只影响白天（乘 df）
	vec3 lmShadow = lm;
	lmShadow.r *= 1.0 - 0.4 * shadowAmt * df;
	vec3 color = albedo * lmShadow;
	// 太阳直射：阴影处完全无直射（硬阴影，亮面/阴影反差清晰）。
	// 0.55 强度：与天光叠加、预曝光 0.62 与 ACES 后沙子不过曝不丢纹理
	float ndl = clamp(dot(n, sd), 0.0, 1.0);
	vec3 sunC = vec3(1.0, 0.92, 0.78) * 0.55;
	color += albedo * sunC * ndl * sh * df * (0.35 + 0.65 * skyLm);
	// 月光
	vec3 md = moonDirV();
	float ndm = clamp(dot(n, md), 0.0, 1.0);
	// 月光（只照到有天空光的地方）：深夜户外天光 1 级 ≈ 0.067 → moonK = 0.335，
	// 月光 0.15×0.335 ≈ 0.05×albedo（与 0.35 基线相当）；洞穴/室内 skyLm=0 → 归零，
	// 修复"无光处被月光抬亮"。clamp 上限防黄昏高天光时月光过爆
	float moonK = clamp(skyLm * 5.0, 0.0, 0.5);
	color += albedo * vec3(0.5, 0.58, 0.85) * 0.15 * ndm * sh * (1.0 - df) * moonK;
	// 环境天光(ambient sky light)：微弱、偏蓝紫、不依赖法线方向的漫反射——
	// 夜晚的背光面（树干阴面、地形背光坡）也能收到极少量天空光，
	// 不再塌成纯黑二维剪纸，能隐约看清材质与起伏。
	// skyLm 门控：洞穴/室内 skyLm=0 → 无环境光，保持漆黑；
	// 法线朝上（n.y 大）的面略亮（天空光主要来自上方）；
	// 白天被 (1.0 - df) 关掉，不影响白昼亮度
	float skyVis = clamp(skyLm * 8.0, 0.0, 1.0);
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
	// 自发光
	color += albedo * emissive * 2.2;
	return color;
}
