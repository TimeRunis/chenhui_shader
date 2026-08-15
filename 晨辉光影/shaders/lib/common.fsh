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
// shadowtex1 = Iris 的"仅不透明深度"图（不含半透明物，如水面）。
// 用 sampler2D 声明手动采样深度值（Iris 硬件深度比较方向不可控
// 实测恒受光）；shadowSample 用手动比较，采 shadowtex1 让水面
// 不再作为遮挡物——水底恢复太阳直射（"水面挡水底阴影"修复）
uniform sampler2D shadowtex1;

// 临时诊断（用后删除）：1 = ndl/sh/df 分解，2 = 最终太阳贡献，0 = 关闭
// 3 = sh 直显（白=受光判定 黑=阴影判定）——受光面阴影定位
#define DEBUG_SUNTERM 0

// 临时调试：沙子方块边缘亮边定位（用后删除）。逐项关闭光照组件，
// 观察亮边是否消失以确定来源：
// 1 = A 关 direct（太阳/月光/方块光全去，只留天光乘法）
// 2 = B 关 shadow（sh 恒受光 1.0，阴影/天光阴影修正全消失）
// 3 = C 关 specular（smoothness=0）
// 4 = D 关 ambient（skyVis=0；本包无 SSAO，此为本包唯一环境光项）
// 5 = E 关 dither（shadow z 抖动与 PCF 旋转 dither 恒 0）
// 6 = 分屏：左半正常、右半关 shadow（sh=1）——一眼对比亮边归属
// 7 = 分屏：左半正常、右半关 direct（太阳/月光/方块光全去）
// 0 = 关闭
#define DEBUG_EDGE 0

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

// 方块光（点光源）颜色：柔和橙黄（火把色系，降饱和版）。
// 乘法式合成 albedo×光色——灰石×暖光 = 暖灰，纹理明暗保留。
// 手持光源（composite1 手持光块）与此共享，放置/手持同色
//（饱和度 0.65 → 0.45：b 0.35 → 0.55 向白收敛，橙黄保留但更柔和）
#define BLOCK_LIGHT_COLOR vec3(1.0, 0.8, 0.55)

// 阳光/月光强度选项（SUN_STRENGTH / MOON_STRENGTH，百分比）：
// lib 约定"不使用选项宏"的例外——两项位于光照合成核心，由各
// .fsh 在 include 前定义；无定义时回退 100（默认强度）
#ifndef SUN_STRENGTH
#define SUN_STRENGTH 100
#endif
#ifndef MOON_STRENGTH
#define MOON_STRENGTH 1000
#endif

// 临时 DEBUG_LIGHT：光照链路分解（"灰白膜"根因验证用，验证后删）
// 0=关闭 1=albedo 2=albedo×ambient光(天光+环境) 3=albedo×direct光
// (方块光+太阳+月光) 4=albedo×(ambient+direct) 5=emissive only
// 7=lightmap 原值 8=skyNight（关键：观察是否随点光源区域变亮=耦合证据）
// 9=blockAmt（与 8 对比空间分布） 10=R=lm.g G=nightK B=skyNight（数值范围）
// 11=R=nightK G=dayFactorF B=lmUV.y（夜晚衰减曲线观察）
#define DEBUG_LIGHT 0

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
// Derivative Main 数学工具（lib/Head/Common.inc）
#define transMAD(m, v) (mat3(m) * (v) + (m)[3].xyz)
#define projMAD(m, v) (vec3((m)[0][0], (m)[1][1], (m)[2][2]) * (v) + (m)[3].xyz)

// 四范数（(x⁴+y⁴)^(1/4)，Derivative ShadowDistortion 的 quarticLength）
float quarticLength(vec2 v) {
	float x2 = v.x * v.x;
	float y2 = v.y * v.y;
	return sqrt(sqrt(x2 * x2 + y2 * y2));
}

// 深度约定（2026-08-13 Derivative 移植后）：
// shadow pass 与采样端同用 ShadowDistortion（xy 畸变 + z×0.2 压缩）——
// 有效深度 ∈ [0, 0.2]（近 0 远 0.2），空区 clear=1.0 恒判受光。
// shadowtex1 = 仅不透明深度（水面不遮挡水底）；Iris 1.7.2 硬件比较
// 实测恒受光（方向不可控），手动采样比较：d + bias > pz 判受光。
// taps: 0=无阴影 1=单采样 2=2x2 PCF
// n: 表面法线（眼空间），经 gbufferModelViewInverse 转世界法线后
// 用于 Derivative 式法线偏移（受光面小偏移、背光面大偏移防 acne）
float shadowSample(vec3 worldPos, vec3 n, int taps) {
	if (taps <= 0) return 1.0;
	// ===== Derivative Main 阴影移植（SunLighting.glsl + ShadowDistortion.glsl
	// + deferred5.fsh normalOffset，2026-08-13） =====
	// ① Iris 的 shadowModelView 接收"相对主相机"坐标——传相对坐标，
	// 否则偏移 cameraPosition 导致投影全部越界
	vec3 relPos = worldPos - cameraPosition;
	// ② 法线偏移（Derivative deferred5 L251 原式）：
	// worldNormal × (dist²×8e-5 + 0.03) × (2 - saturate(NdotL))
	// 沿世界法线推接收面——正对太阳的面（NdotL≈1）偏移最小（受光面
	// 自投影容差，不把自身误判阴影）、背光面（NdotL→0）偏移最大
	// （acne 容差）；偏移随距离平方增长（远处阴影图精度低需更大容差）
	vec3 worldNormal = normalize(mat3(gbufferModelViewInverse) * n);
	float ndlW = clamp(dot(worldNormal, sunDirW()), 0.0, 1.0);
	float dist2 = dot(relPos, relPos);
	vec3 nOff = worldNormal * (dist2 * 8e-5 + 0.03) * (2.0 - ndlW);
	// ③ 投影 + 畸变（ShadowDistortion 原式，与 shadow.vsh 渲染端一致）：
	// xy 四范数畸变（中心纹素密度更高）、z×0.2 深度压缩（精度×5）。
	// 深度语义：渲染端 gl_FragCoord.z = clip.z×0.2 归一化（近 0 远 0.2），
	// 采样端 p.z 同变换；空区 clear=1.0 恒 > 有效深度 → 恒判受光 ✓
	vec3 clipPos = transMAD(shadowModelView, relPos + nOff);
	clipPos = projMAD(shadowProjection, clipPos);
	float distortFactor = quarticLength(clipPos.xy * 1.165) * 0.9 + 0.1; // SHADOW_MAP_BIAS=0.9
	vec3 p = clipPos * vec3(vec2(1.0 / distortFactor), 0.2) * 0.5 + 0.5;
	if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) return 1.0;
	// 阴影图边缘淡出（晨辉保留）：UV 接近边界时阴影权重平滑降到 0，
	// 消除 shadowDistance 边缘"阴影突然消失"的方形硬切
	vec2 uvFade = smoothstep(0.0, 0.04, p.xy) * smoothstep(1.0, 0.96, p.xy);
	float fade = uvFade.x * uvFade.y;
	// ④ PCSS blocker（Derivative BlockerSearch 原式）：8 采样螺旋、
	// 半径 2×shadowProjection[0].x（clip 空间 texel）、weight = step(遮挡, p.z)
	// （Derivative 用遮挡深度 ≤ p.z 计入平均；自身面（==p.z）weight=1 但
	// 半影比例 = 2×(pz-blocker)/blocker ≈ 0 无放大）
	float shadowRes = float(textureSize(shadowtex1, 0).x);
	#if DEBUG_EDGE == 5
	float dither = 0.0; // E：关 dither（z 抖动与 PCF 旋转固定）
	#else
	float dither = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
	#endif
	float ang0 = dither * 6.2831853;
	float searchDepth = 0.0;
	float sumWeight = 0.0;
	float searchRadius = 2.0 * shadowProjection[0].x;
	for (int i = 0; i < 8; i++) {
		float fi = float(i) + dither;
		float ang = ang0 + float(i) * 0.7853981;
		vec2 sampleCoord = p.xy + vec2(cos(ang), sin(ang)) * searchRadius * sqrt(fi * 0.125);
		float ds = texture(shadowtex1, sampleCoord).r;
		float weight = step(ds, p.z); // Derivative: step(depthSample, shadowProjPos.z)
		searchDepth += ds * weight;
		sumWeight += weight;
	}
	float blockerDepth = (sumWeight > 0.001) ? searchDepth / sumWeight : 1.0;
	float penumbraRatio = min(2.0 * (p.z - blockerDepth) / max(blockerDepth, 1e-4), 1.0);
	// ⑤ PCF 半径（Derivative: max(blockerSearch.x / distortFactor, 2.0/res)）
	// ——半影比例 × 投影缩放 / 畸变因子 = clip 空间半径，PCF 在 UV 空间
	// 采样（与 Derivative 的 shadowProjPos 直接相加一致）
	float penumbra = max(penumbraRatio * shadowProjection[0].x / max(distortFactor, 1e-4), 2.0 / shadowRes);
	// ⑥ Poisson PCF（Derivative PercentageCloserFilter 原式）：
	// 16 采样固定（原 taps=1 时 8 采样）——方块侧面半影半径大，
	// 8 采样不足会产生条纹状阴影并随波浪/视角闪烁（用户反馈），
	// 16 采样让条纹显著细化
	int smp = 16;
	float pz = p.z - (1e-4 - dither * 5e-5);  // z 微抖动防 acne
	float s = 0.0;
	int cnt = 0;
	for (int i = 0; i < 16; i++) {
		if (i >= smp) break;
		float fi = float(i) + dither;
		float ang = ang0 + float(i) * 0.7853981;
		vec2 sampleCoord = p.xy + vec2(cos(ang), sin(ang)) * penumbra * sqrt(fi * (1.0 / 16.0));
		// 边界修正（2026-08-13 亮边排查）：采样点越出 shadow UV（默认
		// REPEAT 会采到对侧无意义深度）或落在投影带空区（d>0.995 清屏）
		// 时跳过——两者都会在遮挡边界产生错误亮采样（空区被误当受光
		// 冲淡阴影 = 阴影边界亮边）。有效采样数归一化：投影带内必有
		// 有效深度（p.xy 已判越界 return），cnt 恒 > 0
		if (sampleCoord.x < 0.0 || sampleCoord.x > 1.0 || sampleCoord.y < 0.0 || sampleCoord.y > 1.0) continue;
		float d = texture(shadowtex1, sampleCoord).r;
		if (d > 0.995) continue;
		// 深度比较：受光 d + 微 bias > pz
		s += (d + 1e-4 > pz) ? 1.0 : 0.0;
		cnt++;
	}
	s = (cnt > 0) ? s / float(cnt) : 1.0;
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
	// 深度比较，只计算太阳方向上的遮挡——阴影永远有明确方向。
	// 背光面（背离主光）强制全阴影：太阳/月亮物理上永远照不到背面。
	// 背光面部分像素的阴影图 UV 落主体投影带外 → 误判受光 → 天光
	// 漏光（"背光面梯形阴影"——锐利模式暴露，PCF 软边曾掩盖）。
	// 强制 sh=0 不乘黑：direct 已被下方 ndl=0 乘掉，这里只压天光
	//（skyCorr 阴影区 35%）与月光，保留合理环境光
	float dfL = df;
	vec3 sdMain = (dfL > 0.5) ? sunDirV() : moonDirV();
	float ndlMain = clamp(dot(n, sdMain), 0.0, 1.0);
	float sh = (ndlMain < 0.001) ? 0.0 : shadowSample(worldPos, n, shadowTaps);
	#if DEBUG_EDGE == 2
	sh = 1.0; // B：关 shadow（阴影判定恒受光）
	#elif DEBUG_EDGE == 6
	if (gl_FragCoord.x > viewWidth * 0.5) sh = 1.0; // 分屏：右半关 shadow，左半正常
	#endif
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
	// 方块光掩码（smoothstep(0.003, 0.015, r-g)）已随 skyCorr 的
	// blockMask 保护移除（见下方 skyCorr 注释）
	// 天光分量（仅供 ambient 门控 skyVis 使用，不参与漫反射 light）：
	// 白天阴影衰减 + 夜晚衰减——ambient 只在"天光接近零"时关闭，
	// 夜晚无光处保持弱门控（0.12），环境光不覆盖材质
	float sky = skyRaw * (1.0 - 0.5 * shadowAmt * df);
	sky *= mix(1.0, 0.15, 1.0 - df);
	// ===== 照明合成（亮度锚点 = 原版 r 通道，颜色中性） =====
	// 三分屏 debug 定论：① 原版 lightmap 的 r 通道（max 天光/方块光
	// 显示亮度，永不超原版）是正确亮度锚点——纹理比例原样保留；
	// ② lightmap 的 b 通道（方块光烘焙色 0.2~0.5）会把灰色材质
	// 染成暖橙红（用户反馈"圆石覆盖一层光源颜色"），g 通道夜晚
	// 太低导致颜色失真——颜色改由中性白提供，色温交给太阳项/
	// 月光/环境光项各自负责；③ 合成色温（blockC/skyC、烘焙色
	// 收敛）都会把混合光压偏（红色光斑/洗白），不采用。
	// 方块光超过天光的量（r−g，max 语义），skyCorr 的方块光主导
	// 区判定与 skyNight 共用（过渡带 0~0.3 = 方块光 5.2~8 级）
	float blockAmt = max(lm.r - lm.g, 0.0);
	#if DEBUG_EDGE == 7
	if (gl_FragCoord.x > viewWidth * 0.5) blockAmt = 0.0; // 分屏：右半关 direct（方块光部分）
	#endif
	// 天光阴影修正：阴影处天光 ×(1-0.5×shadowAmt×df)——太阳阴影
	// 可见性的来源（阴影区天光减半 + 无太阳项，与受光区拉开对比；
	// 隔离测试证实恒 1.0 会让阴影几乎不可见）。
	// 方块光主导区（blockAmt 大）阴影衰减按宽过渡抵消（原版
	// lightmap max 语义：火把/萤石照亮区亮度由方块光主导，太阳
	// 阴影不压暗光源区域——"光源减弱太阳阴影"）。过渡带 = blockAmt
	// 0~0.3 2 格以上连续渐变，与夜晚 skyNight 的过渡同构 → 无跳变。
	// 历史：旧版窄过渡保护（smoothstep(0.003, 0.015, r-g)，1~2 级
	// 方块光）造成光斑边缘天光 ×0.5→1.0 陡峭跳变 = "火把一圈灰色
	// 阴影"根因（隔离测试确认）；直接移除保护则火把区天光被阴影
	// 压暗（"光源无法减弱阴影"）——宽过渡兼得两者
	float blockLightK = 1.0 - smoothstep(0.0, 0.3, blockAmt);
	// 天光阴影修正（2026-08-13 参考 Derivative Main 重构 + 可见性平衡）：
	// Derivative 的阴影只乘在太阳直射上，天光由光照图独立表达——但
	// 晨辉直射强度 0.25 低于 Derivative 的 SUNLIGHT_INTENSITY，纯直射
	// 差阴影过淡（用户反馈"阴影强度太低"）。系数 0.35 温和衰减阴影区
	// 天光（×0.65）：开阔地阴影对比 = 直射消失 + 天光 35% 衰减（可
	// 见但不过黑）；低角度太阳受光面下半（顶面自投影区，lm.g 高）
	// 天光 ≈0.63 保留——"微暗受光"而非黑阴影（保留 Derivative 模型的
	// 主要效果）。系数可调范围 0.3~0.5（更高阴影更黑）
	float skyCorr = 1.0 - 0.35 * shadowAmt * df * blockLightK * skyLm;
	// 夜晚低光衰减（按天光 g 平滑 0.25~0.5）：方块光已完全走加法
	// （不衰减——多光源缝隙亮、萤石四周无阴影圈），只有天光需要
	// 夜晚变暗（月光 0.267→0.083，"夜晚接近黑色"）。按 g 连续无
	// 跳变（旧的 r/r−g 掩码衰减在露天光斑边缘制造 1 格内 3~4 倍
	// 跳变 = "萤石四周阴影圈"的根因）；洞穴 g≈0.03 → 天光≈0 自然黑
	float nightK = mix(0.3, 1.0, smoothstep(0.25, 0.5, lm.g));
	// 夜间天光只由 lm.g/时间决定（已解除 blockAmt 耦合）：
	// 旧版 skyNight = mix(nightK, 1.0, smoothstep(0, 0.3, blockAmt))
	// 让点光源越强、夜间环境光越接近白天 1.0——DEBUG 8/9/10 实测
	// skyNight 的空间分布与 blockAmt 光斑完全一致（光斑内 =1.0 白）。
	// 物理语义：火把只增加局部方块光，不把夜间天光恢复成白天
	float skyNight = nightK;
	// 天光：乘法（物理着色——albedo 色相与纹理保留，圆石颗粒清晰）
	// 方块光照明区色温驱动 = 光照图 x 轴真实方块光等级 blockLvlX
	//（lmUV.x = L/16，任何条件下保留——白天直射 r=g=1 顶满、阴影里
	// 光照图天光 g 仍高，r−g 差值恒≈0 → blockAmt 驱动的色温在白天
	// 失效，"放置光源还是白色"根因）。光源照明区域（方块光等级高）
	// 天光基座向 BLOCK_LIGHT_COLOR 变暖；r 恒 1.0 → 色温混合不改变
	// 亮度锚点。亮度语义不变：方块光加亮仍走 blockAmt（原版 max，
	// 不超锚点）
	float blockLvlX = clamp(lmUV.x * 16.0, 0.0, 15.0) / 15.0;
	// 白天衰减：天光强时（阳光直射/开阔地）色温只留 35% 弱暖——
	// 光源照明区的橙黄在光真正贡献的暗处（夜晚/洞穴/阴影）全量，
	// 阳光下的地面不整片偏橙黄（"大地偏橙黄"修复）
	float blockWarm = smoothstep(0.0, 0.2, blockLvlX) * mix(1.0, 0.35, df * skyLm);
	vec3 color = albedo * vec3(lm.g) * skyCorr * mix(1.0, skyNight, 1.0 - df) * mix(vec3(1.0), BLOCK_LIGHT_COLOR, blockWarm);
	#if DEBUG_EDGE == 1
	// A：关 direct——只留天光乘法（太阳/月光/方块光全去）
	return color;
	#endif
	// 方块光：乘法式合成——albedo×[橙黄 BLOCK_LIGHT_COLOR]
	// （"材质颜色 × 光照颜色"，物理着色）：灰色圆石×暖光 = 暖灰，
	// 纹理明暗保留；不再把纯光源色直接加到最终 RGB。
	// blockAmt = max(r−g, 0)：方块光超过天光的量——白天被天光盖住
	// 自动为 0（草/沙子不染黄）；露天光斑边缘从 0 连续渐变（无阴影
	// 圈）；多光源缝隙不衰减（无"缝隙之间的阴影"）。
	// 方向因子 dirF：lightmap 不含光源位置，用"光源在上方"近似——
	// 朝上面（地面）全量、侧墙 0.5、朝下面 0.35——背光面暗于
	// 受光面（"圆石背光面发灰"的根因 = 加法项无方向、所有面均匀亮）
	float dirF = (n.y > 0.0) ? mix(0.5, 1.0, smoothstep(0.0, 0.8, n.y)) : 0.35;
	// 方块光颜色乘法式合成："材质颜色 × 光照颜色"（物理着色）——
	// albedo×暖橙黄（BLOCK_LIGHT_COLOR）= 灰色圆石 × 橙黄光 → 自然暖黄灰，
	// 纹理明暗按 albedo 保留（亮区亮、暗区暗）。旧版把纯光色
	// vec3(1.0,0.5,0.25)×0.15 直接 += 到最终 RGB（不乘 albedo）=
	// 圆石表面蒙一层半透明橙黄、材质颜色与细节被冲淡
	color += albedo * blockAmt * BLOCK_LIGHT_COLOR * dirF;
	// 太阳直射：强度 0.35 → 0.25（用户反馈"沙漠沙子亮度很高"——
	// 沙子 albedo≈(0.76,0.68,0.46)×(0.94 天光 + 0.25×ndl×...) 全天
	// 受光面 ≈1.1×albedo 压进 HDR 压缩边缘发白；0.25 保留阳光方向感
	// 且沙子纹理不再被顶到压缩区）
	// 雨天太阳光衰减（参考 Derivative VolumetricFog:
	// directIlluminance × oneMinus(0.95×wetness)）：阴天云层吸收
	// 阳光——直射几乎归零、阴影变淡，环境天光主导。雨天的冷灰
	// 色调来自"没有太阳光"而非整体混色（色调由此处实现）
	float rainAtten = 1.0 - 0.9 * wetness;
	float ndl = clamp(dot(n, sd), 0.0, 1.0);
	#if DEBUG_EDGE == 7
	if (gl_FragCoord.x > viewWidth * 0.5) ndl = 0.0; // 分屏：右半关 direct（太阳项）
	#endif
	// 阳光色温降饱和 + 加亮（2026-08-14 用户要求）：颜色 (1.0, 0.9, 0.75)
	// → (1.0, 0.95, 0.88)（饱和度 0.25 → 0.12 近白，受光面不偏暖黄）；
	// 强度 0.25 → 0.30（+20%，受光面 0.94+0.30=1.24 仍在 HDR 压缩
	// 阈值 0.85~1.25 内，颜色更白 → 压缩后不发黄）。高光 sunC 同色
	vec3 sunC = vec3(1.0, 0.95, 0.88) * 0.55;
	color += albedo * vec3(1.0, 0.95, 0.88) * (0.30 * (SUN_STRENGTH / 100.0)) * ndl * sh * df * (0.35 + 0.65 * skyLm) * rainAtten;
	// ===== 临时诊断：太阳直射项分解（DEBUG_SUNTERM，用后删除） =====
	// 档 1：R=ndl（法线×太阳方向）G=sh（阴影判定）B=df（天光因子）
	// 档 2：R=最终太阳贡献（含全部因子，灰度：albedo×0.25×SUN×ndl×sh×df×(0.35+0.65×skyLm)×rainAtten）
	#if DEBUG_SUNTERM == 1
	return vec3(ndl, sh, df);
	#elif DEBUG_SUNTERM == 2
	return vec3(0.30 * (SUN_STRENGTH / 100.0) * ndl * sh * df * (0.35 + 0.65 * skyLm) * rainAtten);
	#elif DEBUG_SUNTERM == 3
	return vec3(sh); // 阴影可见性直显：白=受光(1) 黑=阴影(0)——漏光定位
	#endif
	// 月光
	vec3 md = moonDirV();
	float ndm = clamp(dot(n, md), 0.0, 1.0);
	// 月光（只照到有天空光的地方）：深夜户外天光 1 级 ≈ 0.067 → moonK = 0.335，
	// 月光 0.02×0.335 ≈ 0.007×albedo——极淡的冷色轮廓点缀；
	// 洞穴/室内 skyLm=0 → 归零。0.15→0.07→0.04→0.02 连续下调
	float moonK = clamp(skyLm * 5.0, 0.0, 0.5);
	// 月光强度 0.02 → 0.06（用户要求加强）：深夜户外月光
	// 0.06×0.335×ndm ≈ 0.02×albedo——可见的冷色月光，夜晚仍保持暗调
	color += albedo * vec3(0.45, 0.5, 0.75) * (0.06 * (MOON_STRENGTH / 100.0)) * ndm * sh * (1.0 - df) * moonK * rainAtten;
	// 环境天光(ambient sky light)：微弱、偏蓝紫、不依赖法线方向的漫反射——
	// 夜晚背光面（树干阴面、地形背光坡）收到极少量天空光。
	// 门控用衰减后的天光 sky：夜晚户外 0.04×12≈0.48 半开、洞穴≈0 关闭、
	// 白天被 (1.0 - df) 关掉——不覆盖材质，只留一丝轮廓
	float skyVis = clamp(sky * 12.0, 0.0, 1.0);
	#if DEBUG_EDGE == 4
	skyVis = 0.0; // D：关 ambient（本包唯一环境光项；无 SSAO）
	#endif
	// 暗部冷色调环境光：AMBIENT_LIGHT_STRENGTH 强度（0.20 基线 + 法线
	// 朝上略亮）——夜晚暗部呈蓝紫氛围，与月光直射面冷暖对比。
	// 阴影区域环境光再衰减 50%：ambient 不覆盖 shadow，
	// 阴影处比普通暗部更暗，投影轮廓清晰
	vec3 ambC = vec3(0.38, 0.42, 0.68) * (AMBIENT_LIGHT_STRENGTH + 0.08 * n.y);
	color += albedo * ambC * skyVis * (1.0 - 0.65 * shadowAmt) * (1.0 - df);
	// 太阳高光（Blinn-Phong）
	// shiny 上限 150、强度 1.1：水面高光更宽更柔——过窄的高光在波浪流动时
	// 亮点满水面乱跳（"光斑随视角变化"的观感），且 1.5 强度会把反射点过曝成白斑
	#if DEBUG_EDGE == 3
	smoothness = 0.0; // C：关 specular
	#endif
	float shiny = 6.0 + smoothness * smoothness * 150.0;
	vec3 h = normalize(sd + viewDir);
	float ndh = clamp(dot(n, h), 0.0, 1.0);
	vec3 specC = mix(vec3(1.0), albedo, metal * 0.9);
	color += specC * sunC * pow(ndh, shiny) * sh * df * smoothness * 1.1 * rainAtten;
	// 金属漫反射衰减（PBR：金属无漫反射——漫反射项随金属度衰减，
	// 金属面亮度主要来自环境/镜面反射——配合 gbuffers 的天空穹顶
	// 反射，LabPBR 金属方块呈现金属观感而非"带色高光"）
	color *= 1.0 - metal * 0.8;
	// 自发光（emission）：
	// finalColor = surfaceColor(baseColor×lighting) + emission
	// emission = emissiveMask × baseColor × emissionStrength——
	// 发光色继承纹理（亮区发光强、暗区弱），不会替代材质颜色，
	// 也不会把纹理冲淡成纯色；强度 0.45（0.3~0.6 设计范围）。
	// 原版材质无 specular 贴图（emissive 归零）不受影响
	color += albedo * emissive * 0.45;
	// ===== 临时 DEBUG_LIGHT：光照链路分解（验证后删） =====
	#if DEBUG_LIGHT > 0
		vec3 ambLightDbg = vec3(lm.g) * skyCorr * mix(1.0, skyNight, 1.0 - df) * mix(vec3(1.0), BLOCK_LIGHT_COLOR, blockWarm)
		                 + ambC * skyVis * (1.0 - 0.65 * shadowAmt) * (1.0 - df);
		vec3 directDbg = blockAmt * BLOCK_LIGHT_COLOR * dirF
		               + vec3(1.0, 0.95, 0.88) * (0.30 * (SUN_STRENGTH / 100.0)) * ndl * sh * df * (0.35 + 0.65 * skyLm) * rainAtten
		               + vec3(0.45, 0.5, 0.75) * (0.06 * (MOON_STRENGTH / 100.0)) * ndm * sh * (1.0 - df) * moonK * rainAtten;
		#if DEBUG_LIGHT == 1
			return albedo;
		#elif DEBUG_LIGHT == 2
			return albedo * ambLightDbg;
		#elif DEBUG_LIGHT == 3
			return albedo * directDbg;
		#elif DEBUG_LIGHT == 4
			return albedo * (ambLightDbg + directDbg);
		#elif DEBUG_LIGHT == 5
			return albedo * emissive * 0.45;
		#elif DEBUG_LIGHT == 7
			// lightmap 原值直显（R=天光/方块光 max、G=天光、B=烘焙）
			return lm;
		#elif DEBUG_LIGHT == 8
			// 只显示 skyNight（灰白膜验证关键）：点光源区域若整片变白
			// =1.0 → skyNight 被 blockAmt 抬升 = 耦合证据
			return vec3(skyNight);
		#elif DEBUG_LIGHT == 9
			// 只显示 blockAmt：应与火把距离衰减的菱形光斑形状一致，
			// 与 DEBUG 8 的空间分布对比判断耦合
			return vec3(blockAmt);
		#elif DEBUG_LIGHT == 10
			// 数值范围观察：R=lm.g（午夜天光实测值）G=nightK
			// B=skyNight（光斑内/外各记一组，供第二阶段 nightK 曲线定标）
			return vec3(lm.g, nightK, skyNight);
		#elif DEBUG_LIGHT == 11
			// 夜晚衰减观察：R=nightK G=dayFactorF B=lmUV.y（天光级数坐标）
			return vec3(nightK, df, lmUV.y);
		#endif
	#endif
	return color;
}
