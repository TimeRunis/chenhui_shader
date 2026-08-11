#version 450 compatibility

in vec2 texcoord;

// ===== 晨辉光影 选项（各文件定义必须完全一致） =====
#define CLOUDS 2 // 体积云 [0 1 2 3]
#define CLOUD_DENSITY 150 // 云密度 [50 75 100 125 150 175 200]
#define CLOUD_SHADOW 40 // 云影强度 [0 20 40 60 80 100]
#define WATER_REFLECT 1 // 水面反射 [0 1 2]
#define LIGHT_GLOW 100 // 手持光源强度 [0 20 40 60 80 100]
#define LIGHT_FLICKER 1 // 光源闪烁 [0 1]
#define GODRAYS 1 // 丁达尔效应 [0 1 2]
#define SUN_GLOW 80 // 太阳光晕 [[0 25 50 60 75 80 100]]
#define STARS 60 // 星光 [[0 25 30 50 60 75 80 100]]
#define SUN_SIZE 100 // 太阳直径 [0 25 50 75 100]
#define MOON_SIZE 100 // 月亮直径 [0 25 50 75 100]
#define STAR_DENSITY 100 // 星星密度 [0 25 50 75 100]
#define RAIN_DROPS 1 // 雨滴屏幕效果 [0 1]
#define RAIN_WET 1 // 雨天湿润效果 [0 1]
#define SHADOW_QUALITY 1 // 阴影质量 [0 1 2]
#define WAVE_AMOUNT 50 // 波浪强度 [[0 25 30 50 75 100]]
#define UNDERWATER_FOG 1 // 水下雾 [0 1]
#define BRIGHTNESS 100 // 亮度 [50 60 70 80 90 100 110 120 130 140 150]
#define SATURATION 100 // 饱和度 [50 60 70 80 90 100 110 120 130 140 150]
#define CONTRAST 100 // 对比度 [50 60 70 80 90 100 110 120 130 140 150]
#define VIGNETTE 40 // 暗角 [[0 20 30 40 50 60 80 100]]
#define DEBUG_SSR 0 // SSR 调试可视化 [0 1 2 3 4 5 6 7 8 9 10 11] (1=门禁分解 2=ray在屏内 3=深度穿越候选 4=最终命中 5=反射权重 6=反射色 7=colortex3深度快照 8=SSR miss 9=colortex1直显 10=colortex2 albedo直显 11=shadowtex0阴影图)

// colortex0（gbuffers 主颜色 + alpha 方块光等级）用半浮点：
// RGBA8 下 PRE_EXPOSURE 0.62 把漫反射量化精度砍掉 40%，圆石细颗粒
// 纹理差（0.02~0.056）被量化压平（"材质被光照压住"）；16F 下
// 纹值无损往返，HDR 高光（萤石 emission）也精确存储。
// 声明包在块注释里：Iris 加载器识别 /* */ 内的格式 directive，
// 裸声明在 Iris 1.7 会原样进入 GLSL 编译（RGBA16F 未定义 → C1503）
/*
const int colortex0Format = RGBA16F;
// 水面深度 + 水面材质标志存 colortex1（gbuffers_water 写）：
// r = 水面片元深度（gl_FragCoord.z 非线性，32F 精度 2^-24 → 远处
// 误差 < 0.01 格；16F 在 1.0 附近精度 ~2^-11，远处水面 d≈0.995+
// 量化误差经 linDepth 反推放大到数格~上百格 → 反射起点 vp 错位
// = "深水反射消失"）；
// b = 水面材质标志（1 = 水面，0 = 其余——所有 gbuffers 程序显式
// 写，不依赖 buffer 清零；写 a=1 保证 blend 程序下也确定性覆盖）
const int colortex1Format = RGBA32F;
const int colortex2Format = RGBA16F;
// 不透明深度快照（composite1 的 SSR scene depth）：
// colortex3 = 不透明几何深度（gbuffers 不透明程序写 gl_FragCoord.z，
// 水面/雨/云/粒子/手持等半透明程序不写 → 水面像素处保留水底/地形
// 深度，32F 远处精度）。deferred 阶段快照方案不可行（Iris 1.7.2
// 不执行 deferred 程序，实测 colortex3/4 全 0）
const int colortex3Format = RGBA32F;
*/

#include "/lib/common.fsh"
#include "/lib/noise.glsl"
#include "/lib/sky.glsl"
#include "/lib/water.glsl"

uniform sampler2D gcolor;
uniform sampler2D depthtex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2; // gbuffers 材质 albedo（手持光源材质响应）
uniform sampler2D colortex3; // 不透明深度快照（SSR scene depth，gbuffers 写）

// Iris 支持的 OptiFine 兼容 uniform：主手/副手手持方块的光照等级
// （0~15，火把 14、萤石/灯笼 15、空手 0）。uniform 全局共享，
// gbuffers_hand 无需中转，composite 直接读取驱动手持光源
uniform int heldBlockLightValue;
uniform int heldBlockLightValue2;

out vec4 fragOut0;

void main() {
	float d = texture(depthtex0, texcoord).r;
	// 粒子在天空前：粒子不写深度缓冲（MC 粒子 depthMask=false），
	// depthtex0 = 背景天空 1.0 → 下面天空分支会把烟像素判成天空、
	// 刷成天幕色（"烟随机变浅蓝/烟柱被方块遮挡"的根因）。
	// gbuffers_particles 把粒子深度写入 colortex3，这里检测
	// 「depthtex0 是天空但 colortex3 有非天空深度」= 半透明物体
	// 盖在天空上 → 改用 colortex3 深度（粒子真实距离，天空判定与
	// 雾距离随之正确）。纯天空两者都是 1.0 → 不替换
	float dO = texture(colortex3, texcoord).r;
	if (d > 0.9995 && dO < 0.9995) d = dO;
	vec3 color = texture(gcolor, texcoord).rgb;
	// SSR 调试变量（DEBUG_SSR 可视化用，默认不产生任何开销）
	float dbgSsrWater = 0.0;  // waterMask：水面识别（alpha+深度+邻居一致性）
	float dbgSsrScreen = 0.0; // screenValid：ray 是否仍在屏幕范围内
	float dbgSsrCand = 0.0;   // hitCandidate：深度穿越候选（pLin>hitLin）
	float dbgSsrHit = 0.0;    // rayHit：最终命中（穿越+高度过滤+未出屏）
	float dbgSsrW = 0.0;      // reflectionWeight：最终反射混合权重
	vec3 dbgSsrCol = vec3(0.0); // SSR 反射色（线性域）
	float dbgSsrMiss = 0.0; // SSR miss（无任何命中 → 弱环境 fallback）
	float dbgWd = 0.0;    // 水面深度门禁值（colortex1.r，debug 1/9 用）
	float dbgWFlag = 0.0; // 水面材质标志门禁值（colortex1.b，debug 1/9 用）
	// 天空判定（双保险）：深度≈1 且（距离达到投影远平面 98% 或超过雾端）。
	// 只靠 d>0.9995 会把渲染距离边缘的远处方块（深度同样≈1）误判成天空、
	// 刷成天幕色 → "方块被裁剪"；两个距离条件任一成立即天空，对 fogEnd 异常也健壮
	float dist = length(viewPosFromDepth(d, texcoord));
	// 大气散射雾参数（if/else 共用）：颜色随视线高度渐变——
	// Rayleigh 散射下天顶方向散射路径短、雾呈蓝色；地平线方向路径最长、
	// 蓝光被散射殆尽 → 雾色偏暖白。昼夜用 dayFactorF 插值，
	// 不再直接用 MC fogColor（白天近白，会把远景抹成白板）
	vec3 fogDirW = normalize(mat3(gbufferModelViewInverse) * normalize(viewPosFromDepth(d, texcoord)));
	float fogUp = max(fogDirW.y, 0.0);
	float dfFog = dayFactorF();
	// 与天空同源的黄昏暖色分量：太阳低时雾带橙粉环境光色，
	// 不再是纯灰——远山/远景的雾气色调随昼夜与太阳高度呼吸
	vec3 sdFog = sunDirW();
	float sdYFog = clamp(sdFog.y, 0.0, 1.0);
	float warmFog = exp(-sdYFog * 9.0) * smoothstep(0.10, 0.30, dfFog);
	vec3 fogWarm = mix(vec3(0.95, 0.60, 0.35), vec3(0.80, 0.45, 0.60), 0.4);
	vec3 fogZenith = mix(vec3(0.015, 0.03, 0.065), vec3(0.36, 0.55, 0.78), dfFog)
	               + fogWarm * warmFog * 0.15;
	// 地平线雾色：夜晚深邃冷青蓝（融入夜空，不再形成白灰亮带）、
	// 白天清亮蓝白（去掉浑浊黄灰）；黄昏由 warmFog 转暖橙粉
	vec3 fogHorizon = mix(vec3(0.035, 0.05, 0.085), vec3(0.66, 0.76, 0.88), dfFog);
	fogHorizon = mix(fogHorizon, fogWarm, warmFog);
	vec3 fogC = mix(fogHorizon, fogZenith, pow(fogUp, 0.5));
	// 雾浓度峰值：白天 0.30、夜晚 0.08——浓度大幅下调，
	// 远景地形轮廓保留更多层次，不被雾染灰
	float fogAmt = 0.08 + 0.22 * dfFog;
	if (d > 0.9995 && (dist > far * 0.98 || dist > fogEnd)) {
		vec3 vp = viewPosFromDepth(d, texcoord);
		vec3 viewDir = normalize(vp);
		// 世界空间视线（天空随世界转动，不绑定视角）
		vec3 worldDir = normalize(mat3(gbufferModelViewInverse) * viewDir);
		color = getSkyColor(worldDir, STARS / 100.0, SUN_GLOW / 100.0, SUN_SIZE / 100.0, MOON_SIZE / 100.0, STAR_DENSITY / 100.0, float(CLOUDS), float(CLOUD_DENSITY) / 100.0);
		// 太阳泛光：屏幕空间投影位置（盘面细节在 sky.glsl sunDetail 中世界空间绘制）
		vec4 sunClip = gbufferProjection * vec4(sunPosition, 1.0);
		if (sunClip.w > 0.0) {
			vec2 sunUV = sunClip.xy / sunClip.w * 0.5 + 0.5;
			// 纵横比修正：屏幕空间保持圆形
			vec2 sunS = vec2(sunUV.x * aspectRatio, sunUV.y);
			vec2 tS = vec2(texcoord.x * aspectRatio, texcoord.y);
			float sunDist = distance(tS, sunS);
			// 紧致光晕 + 宽泛光（双指数衰减；×0.5 防白昼泛光刺眼）
			color += vec3(1.0, 0.8, 0.55) * exp(-sunDist * 35.0) * (SUN_GLOW / 100.0) * 0.45;
			color += vec3(1.0, 0.72, 0.45) * exp(-sunDist * 9.0) * (SUN_GLOW / 100.0) * 0.25;
		}
		// 下方雾混合必须用世界空间高度：
		// 若用 viewDir.y（视空间），垂直仰视时屏幕边缘恰好 y≈0，会被误判为地平线，
		// 在画面上形成一圈"伪地平线/雾带"；改世界空间后与天空渐变一致，任意视角平滑
		float hz = pow(max(1.0 - worldDir.y, 0.0), 2.5);
		// 天空底部（地平线方向）混入大气雾色，与地面远雾颜色衔接一致。
		// 混合系数 0.45（原 0.70）：夜晚雾色已压暗为深邃青蓝，
		// 若仍 70% 会把天空底部染成一道白灰亮带
		color = mix(color, fogC, hz * 0.45);
		// getSkyColor 返回线性原值（未乘 PRE_EXPOSURE）——这里补乘
		// 进入预曝光域，随主管线 line 172 的 ×1/0.62 恢复。否则天空
		// 会被放大 1.61 倍：高空中渲染距离圆外的"天空像素"整体过曝
		// （"圆外曝光严重"），太阳泛光/云也亮一档
		color *= PRE_EXPOSURE;
	} else {
		// ===== 方块光屏幕空间扩散（圆形光源） =====
		// gbuffers 已把方块光亮度写入 colortex0 的 alpha。MC 方块光按曼哈顿距离
		// 衰减（菱形），纹理域平滑改不了形状，屏幕空间圆形核扩散削尖角：
		// 5x5 自适应半径（R = 屏幕高度 1.6%，1080p ≈ 17px，步长 R/2），深度感知
		// 加权（同一表面才混合，阈值随距离放宽），比率法把扩散量乘回颜色。
		// 颜色修正三重保护，避免"方块边缘黑白描边"：
		// ① 软阈值 str：只对光斑轮廓（低方块光像素）修正，内部方块（origB≥0.34）
		//    完全不改颜色 → 内部方块边缘零描边；② 响应压缩 0.4：factor 偏离 1 的
		//    幅度减半以上，过渡柔和；③ clamp [0.7, 1.3] 兜底防极端。
		// 采样点越界跳过，屏幕边缘不被纹理 clamp 污染。
		// 只对有点光的像素执行，纯黑场景零开销
		float origB = texture(gcolor, texcoord).a;
		if (origB > 0.004) {
			// 半径 0.8%（原 1.6%→1.1%）：光源影响范围收窄——方块光
			// 本身已有距离衰减（calcLight 幂压缩），屏幕扩散只需
			// 削平 16 级阶梯的边缘，不需要额外扩大光斑半径
			float R = max(5.0, viewHeight * 0.008);
			float st = R * 0.5;
			vec2 px = vec2(1.0 / viewWidth, 1.0 / viewHeight);
			float diffB = 0.0;
			float wsum = 0.0;
			for (int i = -2; i <= 2; i++) {
				for (int j = -2; j <= 2; j++) {
					vec2 off = texcoord + vec2(float(i), float(j)) * st * px;
					if (off.x < 0.0 || off.x > 1.0 || off.y < 0.0 || off.y > 1.0) continue;
					float d2 = texture(depthtex0, off).r;
					// 深度权重更严格（0.15 起、斜率放缓）：相邻方块表面
					// 深度差更大 → 权重更快降 0，光不跨方块边界泄漏
					float w = 1.0 - smoothstep(0.15, 0.7 + dist * 0.015, abs(linDepth(d2) - dist));
					diffB += texture(gcolor, off).a * w;
					wsum += w;
				}
			}
			if (wsum > 0.5) {
				diffB /= wsum;
				// +0.015 保护：origB 接近 0 时（光源最外缘）f0 收敛到 1 附近，
				// 不会把过渡带压成黑洞，也不会放大亮度噪声
				float f0 = (diffB + 0.015) / (origB + 0.015);
				float str = 1.0 - smoothstep(0.22, 0.34, origB);
				// 响应压缩 0.2、clamp [0.9,1.1]：萤石边缘对零亮度邻块的
				// 提亮压到 ×1.1，光晕收敛到几乎察觉不到，消除
				// "方块接缝漏光"的异常亮条
				float factor = clamp(1.0 + (f0 - 1.0) * 0.2 * str, 0.9, 1.1);
				color *= factor;
			}
		}
		// 距离雾：起于 fogEnd 的 80%（原 50%——100 方块就起雾太早），
		// fogEnd（渲染距离边缘）处才达到峰值 fogAmt（白天 0.30、夜晚 0.08）。
		// 雾在 300~400 方块外才开始主要遮挡，远景轮廓清晰保留；
		// 颜色用大气散射渐变 fogC（天顶蓝/地平线冷蓝或暖白）。
		// 视距边缘过渡：fogEnd 的 90%~100% 区间雾浓度额外补满到 1.0——
		// 最外圈方块完全融入雾色，与天空分支（hz×0.45 混 fogC）衔接，
		// 消除渲染距离圆的锐利边缘（旧雾峰 0.30 时外圈方块仍清晰，
		// 与远处天空对比成一道锐利圆环）
		float fogEdge = smoothstep(fogEnd * 0.9, fogEnd, dist);
		float fogF = mix(smoothstep(fogEnd * 0.8, fogEnd, dist) * fogAmt, 1.0, fogEdge);
		// 雾色必须乘 PRE_EXPOSURE 进入预曝光域再混合：color 来自
		// gcolor（gbuffers 已乘 0.62），若用线性 fogC 直混，雾分量
		// 会随主管线 ×1/0.62 放大 1.61 倍——白天雾色 (0.66,0.76,0.88)
		// → (1.06,1.22,1.42) 全超 1，远景方块被钳成过曝泛白。
		// 天空分支无此问题：先混雾、最后整体 ×PRE_EXPOSURE
		color = mix(color, fogC * PRE_EXPOSURE, fogF);
	}
	// ===== 水下雾（线性空间） =====
	// 眼睛在水中（isEyeInWater=1）时原版靠水下雾让远处景物被水色遮蔽——
	// 缺失会让水底/水下远景清晰发亮。按距离混向深蓝绿水色：
	// 8 格 ≈38%、20 格 ≈70%、50 格 ≈95%，近处景物仍可辨认
	if (isEyeInWater > 0.5) {
		float fogUnder = 1.0 - exp(-dist * 0.06);
		color = mix(color, vec3(0.07, 0.20, 0.30), fogUnder);
	}
	// ===== 逆预曝光 + HDR 软压缩（修复光斑压平与高光溢出） =====
	// gbuffers 写入前已乘 PRE_EXPOSURE 0.62（把 HDR 压进 RGBA8 量化范围），
	// 这里恢复 color × 1/0.62（≈1.6129）再乘 BRIGHTNESS/100（亮度选项）。
	// 不再做整体曝光收敛（原 ×0.62）：它会连光源光斑内部的亮度递减
	// 一起压平——"光照没有递减、只有边缘突然下降"的根因之一
	color *= (1.0 / PRE_EXPOSURE) * (BRIGHTNESS / 100.0);
	// ===== 水面反射（SSR 屏幕空间光线步进） =====
	// gbuffers_water 把水面 alpha 恒写 0.65（原版水面纹理透明度，
	// 恢复真实水面半透明状——透出 35% 水底材质，浅水区能看清
	// 水底颜色）。识别 = alpha∈(0.63,0.67) + 反射方向朝下
	// （R.y<−0.05）排除墙面光源（视线平视、反射不朝下），
	// + 4 邻居 alpha 一致性排除地面光源误判：方块光 13 级
	// （blockSourceLevel 恰为 0.82）周围 alpha 渐变（0.94/0.88/0.76），
	// 而水面大片恒定 0.65——俯视萤石旁 2 格不会触发反射。
	// 反射色采样自 colortex0（gbuffers 原始预曝光域），×1/PRE_EXPOSURE
	// 恢复到与 color 同域，随主管线一起过 HDR 压缩与暗部保护。
	// 未命中/出屏回退天空色（与主天空同一函数同一雾混合），
	// 命中点再按距离补雾——远岸山体反射不会突兀清晰
	{
		// 眼睛在水下时不做 SSR：水下抬头视线从下往上穿过水面，
		// 反射方向 R=reflect(viewDir,nV) 朝下回到水里——SSR 会在
		// 水下找"反射内容"（物理错误：水下看水面是透射看天空，
		// 不是反射）。跳过 SSR 后水面显示 gcolor 混合内容
		// （水色×0.65 + 35% 透过的水下景物/天空）
		// 水面识别（v3 材质标志）：colortex1.b = 水面材质标志——
		// gbuffers_water 显式写 1.0，其余所有 gbuffers 程序显式写
		// 0.0（写 a=1 保证 blend 程序下也确定性覆盖）。不再用
		// gcolor.a=0.65 数值巧合（与方块光等级解耦），不依赖
		// colortex1 每帧清零。三重门禁：
		// ① 材质标志 = 1（唯一的水面身份来源）
		// ② colortex1.r = 水面深度 > 0.05（深度有效——排除未写入
		//    的 0；旧阈值 0.5 = 距离 0.2 块，眼睛贴水（游泳/蹲水里）
		//    低头时最近的水面像素距离 < 0.2 块被整片排除 = "低头到
		//    某角度水面变原版 + debug 5 全黑"的根因）
		// ③ depthtex0 与该深度一致（水面像素的最前深度必然等于
		//    水面深度本身——覆盖/blend 造成的 stale 标志残留像素
		//    （手持透明物品等）过不了这一关）
		if (WATER_REFLECT > 0 && isEyeInWater < 0.5) {
			dbgWd = texture(colortex1, texcoord).r;
			dbgWFlag = texture(colortex1, texcoord).b;
			if (dbgWd > 0.05 && dbgWFlag > 0.5 && abs(texture(depthtex0, texcoord).r - dbgWd) < 0.001) {
			float d = dbgWd;
			vec3 vp = viewPosFromDepth(d, texcoord);
			vec3 viewDir = normalize(vp);
			// 水面像素世界位置：SSR 命中排除水下物体用（命中点世界
			// 高度 ≤ 水面高度 = 在水下 → 反射射线不穿水，水下物体
			// 经透射显示，不参与反射）
			vec3 waterWp = worldPosFromView(vp);
			// 世界位置 → 同一水面波浪法线（与 gbuffers_water 同函数，
			// 波纹随时间流动，反射方向逐帧变化 = 涟漪自然晃动）
			vec3 nV = normalize(mat3(gbufferModelView)
				* waterNormalWorld(worldPosFromView(vp),
					(WAVE_AMOUNT / 100.0) * 0.9 * (1.0 + wetness * 1.2)));
			vec3 R = reflect(viewDir, nV);
			// 不限制反射方向：平视/微俯看远处水面时反射方向朝上
			// （反射天空、远岸山体）——这是水面反射最常见的场景。
			// 水面身份由 colortex1.b 材质标志唯一确定，不再需要
			// 4 邻居 alpha 一致性启发式（它曾在岸边把最浅一圈
			// 水面排除出 SSR = 1px mask 内缩，随启发式一起移除）
			{
					vec3 Rn = normalize(R);
					vec3 Rw = normalize(mat3(gbufferModelViewInverse) * Rn);
					// 环境弱 fallback（仅 SSR miss 时用，8% 强度）：与主
					// 天空同参数同雾混合。任何 miss（出屏/无交点/走满
					// 步数/饱和路径无可靠交点）都不允许把天空当等价
					// 反射以 Fresnel 全权重混入（SSR-2）
					vec3 envWeak = getSkyColor(Rw, STARS / 100.0, SUN_GLOW / 100.0, SUN_SIZE / 100.0, MOON_SIZE / 100.0, STAR_DENSITY / 100.0, float(CLOUDS), float(CLOUD_DENSITY) / 100.0);
					float hzR = pow(max(1.0 - Rw.y, 0.0), 2.5);
					envWeak = mix(envWeak, fogC, hzR * 0.45);
					// 光线步进：屏幕空间 marching（参照 Derivative Main 的
					// ScreenSpaceRayTrace）。坐标：rayPos.xy=像素坐标、
					// rayPos.z=非线性深度(0~1,大=远)。scene depth 取自
					// colortex3（gbuffers 不透明程序写的几何深度，水面等
					// 半透明程序不写 = 不透明深度快照，等价 Derivative 的
					// depthtex1）——射线不与水面自身相交（无需穿透 hack），
					// 反射内容直接采样 gcolor。自适应步长：当前深度差 ×
					// 权重，近表面自动收敛、远离表面大步跨，无固定距离
					// 参数；命中 = 场景深度 < 射线深度 且线性相对差 <20%
					// （防大步长远处误命中薄表面）。出屏/深度超界 = miss
					// （回退按反射方向的天空）
					int steps = (WATER_REFLECT > 1) ? 32 : 24; // 步数提高：扩大 marching 屏幕覆盖范围
					// 屏幕空间反射方向：起点水面像素 → 反射方向远点。
					// 最小延伸 4 块：眼睛贴水时 |vp.z| 可小到 0.1，
					// target 过近 → screenDir 退化为零向量（NaN）
					vec4 tarClip = gbufferProjection * vec4(vp + R * max(abs(vp.z), 4.0), 1.0);
					vec3 target = vec3(tarClip.xy / tarClip.w * 0.5 + 0.5,
						tarClip.z / tarClip.w * 0.5 + 0.5) * vec3(viewWidth, viewHeight, 1.0);
					vec3 screenDir = normalize(target - vec3(gl_FragCoord.xy, dbgWd));
					float stepWeight = 1.0 / max(abs(screenDir.z), 1e-5);
					// 像素空间步长钳制（Derivative 在 UV 空间 clamp，转像素
					// 后等价）：minLength=1px、maxLength=屏长/步数
					float maxLength = max(viewWidth, viewHeight) / float(steps);
					float minLength = 1.0; // 1 像素
					vec3 acc = vec3(0.0);
					int hitCount = 0; // SSR 命中遍数（miss 判定与命中平均用）
					for (int k = 0; k < ((WATER_REFLECT > 1) ? 2 : 1); k++) {
						vec3 col = vec3(0.0); // 本遍命中色（miss 保持 0，不再初始化成天空）
						// 起点 = 水面像素（像素坐标 + 非线性深度）；高档第 2
						// 遍相位抖动（±3 像素）→ 波纹亚步长模糊
						vec3 rayPos = vec3(gl_FragCoord.xy, dbgWd);
						if (k == 1) rayPos += screenDir * 3.0;
						// 第一跳：跨到屏幕边界的步长/步数（防止第一步跳出
						// 屏幕），起点额外推进 dither×步长 + 1 像素
						// （射线不贴着起点表面开始，避免第一步就与自身
						// 表面的深度差≈0 误命中）——同 Derivative
						// rayPos += rayStep*dither + screenDir*minLength。
						// 边界公式对应像素/深度坐标轴上限（Derivative 在
						// UV 空间用 (1-pos)/dir，像素空间上限 = viewWidth
						// /viewHeight，z 轴上限 1.0 不变）
						vec3 boundary = (step(0.0, screenDir) * vec3(viewWidth, viewHeight, 1.0) - rayPos) / screenDir;
						float stepLength = min(min(boundary.x, boundary.y), boundary.z) / float(steps);
						rayPos += screenDir * (stepLength * 0.5 + minLength);
						float depth = texelFetch(colortex3, ivec2(rayPos.xy), 0).r;
						for (int i = 0; i < steps; i++) {
							// 出屏 → miss（ray 飞出屏幕，回退天空）
							if (rayPos.x < 0.0 || rayPos.x > viewWidth || rayPos.y < 0.0 || rayPos.y > viewHeight) break;
							// ray 仍在屏内（debug 2：screenValid）
							dbgSsrScreen = 1.0;
							// 自适应步长（1px ~ 1/步数 屏长钳制）
							stepLength = abs(depth - rayPos.z) * stepWeight;
							rayPos += screenDir * clamp(stepLength, minLength, maxLength);
							depth = texelFetch(colortex3, ivec2(rayPos.xy), 0).r;
							// z 饱和（rayPos.z>=1.0）不 break：非线性深度在
							// 远处快速饱和（远处水面 wd≈0.9995，旧代码走
							// 1~2 步就 break = "反射区域≈浅水区面积"的根因
							// ——只有近处水面能走完 marching）。饱和后射线
							// = 向无限远延伸，远处地形（linDepth<far）必被
							// 穿过 → 直接命中：跳过相对差与二分细化（远处
							// 内容在屏幕上变化慢，采样偏差亚像素级无感），
							// 大步长快速扫过远处区域；天空 depth=1.0 仍
							// 排除（linDepth=far，不比射线近）→ miss 回退
							if (rayPos.z >= 1.0) {
								vec2 suvH = rayPos.xy * vec2(1.0 / viewWidth, 1.0 / viewHeight);
								vec3 hitWp = worldPosFromView(viewPosFromDepth(depth, suvH));
								// 高度判据照常：水底/水下物体仍被排除；
								// 天空（depth=1.0，far 平面高度必高于水面）单独
								// 排除 → miss 回退 getSkyColor（与命中天空 gcolor
								// 等价，但走统一回退路径）
								if (depth < 1.0 && hitWp.y > waterWp.y + 0.15) {
									dbgSsrCand = 1.0;
									// 反射内容 = 当前像素 gcolor（远处低频）
									vec2 suv = rayPos.xy * vec2(1.0 / viewWidth, 1.0 / viewHeight);
									col = texture(gcolor, suv).rgb * (1.0 / PRE_EXPOSURE);
									float rDist = length(viewPosFromDepth(depth, suv));
									float fogEdge = smoothstep(fogEnd * 0.9, fogEnd, rDist);
									float fogF = mix(smoothstep(fogEnd * 0.8, fogEnd, rDist) * fogAmt, 1.0, fogEdge);
									col = mix(col, fogC, fogF);
									dbgSsrHit = 1.0;
									break;
								}
							}
							// 命中候选：场景深度 < 射线深度（射线在表面后面）
							else if (depth < rayPos.z) {
								float lS = linDepth(depth);
								float lC = linDepth(rayPos.z);
								// 相对阈值 0.2：线性深度相对差 <20% 才算命中
								// （防大步长远处误命中薄表面/深度跳变）
								if (abs(lS - lC) / lC < 0.2) {
									// 高度判据在下方通过后才算候选
									vec2 suvH = rayPos.xy * vec2(1.0 / viewWidth, 1.0 / viewHeight);
									vec3 hitWp = worldPosFromView(viewPosFromDepth(depth, suvH));
									vec3 rayWp = worldPosFromView(viewPosFromDepth(rayPos.z, suvH));
									if (rayWp.y < waterWp.y) break;
									// 高度判据（v2）：命中点必须高于水面——物理
								// 镜面反射的内容在镜子之上。旧判据
								// hitWp.y>rayWp.y 在俯视浅水区失效：ray 沿
								// 屏幕向上走到更远处的浅水区像素，那些像素
								// 视线斜向下，深度穿越必伴随"近点更高"→
								// 水底/水下海带照常命中（反射区域≈浅水区
								// 面积、水草出现在反射里的根因）。改以水面
								// 高度为基准：水底永远低于水面 → 排除；
								// 岸边/山体/建筑高于水面 → 保留。容差
								// 0.15 = 波浪起伏(±0.05) + 深度重建误差
								if (hitWp.y > waterWp.y + 0.15) {
									dbgSsrCand = 1.0;
										// 二分细化 6 步收敛到精确交点（防反射
										// 内容像素级错位）
										vec3 rayStep = screenDir * stepLength;
										for (int r = 0; r < 6; r++) {
											if (rayPos.x < 0.0 || rayPos.x > viewWidth || rayPos.y < 0.0 || rayPos.y > viewHeight) break;
											rayStep *= 0.5;
											depth = texelFetch(colortex3, ivec2(rayPos.xy), 0).r;
											if (depth < rayPos.z) rayPos -= rayStep;
											else rayPos += rayStep;
										}
										// 命中点必须是非天空场景（depth<1.0）
										if (depth < 1.0) {
											vec2 suv = rayPos.xy * vec2(1.0 / viewWidth, 1.0 / viewHeight);
											// 反射内容 = gcolor 直接采样：命中点
											// 满足「深度穿越 + 表面高于射线」——只
											// 可能是高于射线的真实表面（岸/山/建筑），
											// 永不落在水面像素（水面像素深度=水底<
											// 射线，高度判据排除）→ gcolor 的透明
											// 混合污染不影响反射
											col = texture(gcolor, suv).rgb * (1.0 / PRE_EXPOSURE);
											// 反射点距离雾：与主场景同参
											// （fogEnd 80% 起，90%~100% 视距
											// 边缘补满到 1.0）
											float rDist = length(viewPosFromDepth(rayPos.z, suv));
											float fogEdge = smoothstep(fogEnd * 0.9, fogEnd, rDist);
											float fogF = mix(smoothstep(fogEnd * 0.8, fogEnd, rDist) * fogAmt, 1.0, fogEdge);
											col = mix(col, fogC, fogF);
											dbgSsrHit = 1.0;
											break;
										}
									}
								}
							}
						}
						if (dbgSsrHit > 0.5) { acc += col; hitCount++; } // 只累计命中遍（miss 遍不稀释）
						dbgSsrHit = 0.0; // 逐遍清零，避免上一遍命中污染下一遍判定
					}
					// SSR hit/miss 分离（SSR-2）：
					vec3 refl;
					if (hitCount > 0) {
						// HIT：命中色平均（miss 遍不稀释），Fresnel 权重不变
						refl = acc / float(hitCount);
					} else {
						// MISS 分级（SSR-2 修订）：
						// 反射方向明显朝天（Rw.y > 0.35 = 低头看水面）时，
						// 天空是物理正确的反射内容——俯视水面的倒影就是
						// 头顶天空（天顶色暗，不像地平线亮雾带刺眼），给
						// 可见强度（最高 0.45，随 Rw.y 渐变）：低头时反射
						// 不"消失"，水面持续有反射内容（debug 4 置位）。
						// 接近地平线（Rw.y ≤ 0.35 = 平视深水）时压到极弱
						// （0.05~0.12）——旧版"深水天空镜面"的刺眼来源
						float missK;
						if (Rw.y > 0.35) {
							missK = 0.45 * smoothstep(0.35, 0.7, Rw.y);
						} else {
							missK = mix(0.05, 0.12, clamp(Rw.y, 0.0, 1.0));
						}
						refl = mix(color, envWeak, missK);
					}
					// debug 语义：hit = 有反射内容（几何命中或俯视天空
					// 反射），miss = 无内容（弱 fallback）
					dbgSsrHit = (hitCount > 0 || Rw.y > 0.35) ? 1.0 : 0.0;
					dbgSsrMiss = (hitCount == 0 && Rw.y <= 0.35) ? 1.0 : 0.0;
					dbgSsrCol = refl;
					// 菲涅尔反射率：俯视 0.45、掠射 0.9（用户选择增强——
					// 俯视时附近方块/光源/日月反射明显可见，掠射近全反射）
					float reflK = 0.45 + 0.45 * pow(1.0 - dot(-viewDir, nV), 3.0);
					// Fresnel 权重（本轮保持原值，SSR-3 再重构）：
					// 俯视 0.45、掠射 0.9。miss 时反射内容已是弱 fallback，
					// 权重不再决定"天空镜面"强度
					dbgSsrW = reflK;
					color = mix(color, refl, reflK);
					// 波光粼粼（太阳镜面高光）独立叠加：所有水面像素都有
					// ——无命中区域保留弱波光（0.5×），波浪法线让反射方向
					// 晃动 = 星星点点的波纹闪烁。夜晚弱化只留月光
					vec3 sunSpec = vec3(1.0, 0.8, 0.55)
						* pow(max(dot(Rn, sunDirV()), 0.0), 350.0) * (0.15 + 0.85 * dfFog);
					color += sunSpec * mix(0.5, 1.0, reflK);
			}
			}
		}
	}
	// ===== 手持光源（玩家手持光源方块照亮周围） =====
	// heldBlockLightValue（OptiFine 兼容 uniform，Iris 支持）：主/副手
	// 持发光方块时 = 其方块光等级（火把 14、萤石/灯 15），空手 = 0。
	// 强度与范围对应放置光源：连续线性衰减（0~0.5 格满亮度、之后
	// 每格降 1 级，火把 14 级 → 14.5 格归零）——连续无阶梯，
	// 不产生同心圆环；中心亮度 = 等级/15 ≈ 放置光源中心。
	// 颜色从手持物品材质提取（gbuffers_hand 把物品 albedo 写 colortex1，
	// 此处采样屏幕物品区域亮部平均色）：火把暖橙、萤石白、灯笼橙、
	// 海晶灯蓝白——随手持物品变化。
	// 材质响应：手持光乘 gbuffers 写入 colortex2 的 albedo——显示
	// 亮度 = 方块光等级 × 材质颜色，与放置光源完全同构；材质纹理
	// 清晰可见（裸加法会糊成纯色光罩：0.93 白 × 石头 0.5 = 0.47 灰白
	// 而非 0.93 纯白，中心不再过曝）。
	// 白天被环境光淹没（乘 0.35），夜晚全量，与放置光源被天光盖过
	// 的观感一致。光源本体（物品像素）不叠光源色，改为亮度提升：
	// 材质颜色与纹理对比原样保留，呈现"清晰被照亮的材质"
	float heldLight = max(float(heldBlockLightValue), float(heldBlockLightValue2)); // 0~15
	if (LIGHT_GLOW > 0 && heldLight > 0.01) {
		// 右手持物位置（相机空间：X 右、Y 上、Z 屏幕内），距眼睛约 0.8 格
		vec3 handPos = vec3(0.40, -0.32, -0.60);
		vec3 vpH = viewPosFromDepth(d, texcoord);
		// 光源本体掩码（近距离区分物品像素）
		float hd = length(vpH - handPos);
		float bodyK = 1.0 - smoothstep(0.30, 1.0, hd);
		// 圆形光斑：欧几里得距离，半径 = 等级×0.8（火把 ≈11.7 格、
		// 萤石 ≈12.5 格）——与原版放置光源范围等效（曼哈顿菱形 14 格
		// 的面积 ≈ 半径 11 格圆）。中心亮度按等级映射：火把 0.93、
		// 萤石 1.0，与放置光源中心一致
		float rad = heldLight * 0.8 + 0.5;
		// 光衰减改 smoothstep（旧 clamp 线性衰减的边缘导数不连续：
		// 深度重建噪声让 hd 在光斑边缘抖动 → 亮度硬边闪烁）
		float hatt = 1.0 - smoothstep(0.0, rad, hd);
		hatt *= heldLight / 15.0;
		// 白天衰减：环境光强时手持光被淹没（放置火把白天同样不显）
		float dayW = mix(1.0, 0.35, dfFog);
		// 光源颜色：屏幕物品区域（右下）7×7 采样 colortex1。权重用
		// 三通道最小值——纯色残留（水面深度 r 通道残留=偏红、旧帧
		// 暗部）min≈0 被排除，火把火焰/萤石亮面（三通道都亮）主导，
		// 消除偶发变红
		vec2 px = vec2(1.0 / viewWidth, 1.0 / viewHeight);
		vec3 lsum = vec3(0.0);
		float wsum = 0.0;
		for (int i = -3; i <= 3; i++) {
			for (int j = -3; j <= 3; j++) {
				vec2 off = vec2(0.75, 0.28) + vec2(float(i), float(j)) * viewHeight * 0.025 * px;
				if (off.x < 0.0 || off.x > 1.0 || off.y < 0.0 || off.y > 1.0) continue;
				vec4 c1x = texture(colortex1, off);
			vec3 lc = vec3(c1x.r, c1x.g, c1x.a); // r/g/a = 手持物品 albedo×等级（b = 水面材质标志，不入采样）
				float w = max(min(lc.r, min(lc.g, lc.b)) - 0.1, 0.0);
				lsum += lc * w;
				wsum += w;
			}
		}
		vec3 lcol = vec3(1.0, 0.88, 0.65); // 回退：暖白（采样失败时不会突兀变红）
		if (wsum > 0.01) {
			lcol = lsum / wsum;
			lcol = lcol / max(max(lcol.r, lcol.g), max(lcol.b, 1e-4));
			// 色相钳制在暖白~橙带内（g∈[0.72,0.98]、b∈[0.35,0.90]），
			// 再向暖白收敛 70%：火焰动画帧/物品摆动让采样区域内容
			// 逐帧变化 → lcol 抖动 → 光照闪烁；更强收敛压掉抖动，
			// 火把橙/萤石白/海晶灯蓝白的差异仍可辨
			lcol = vec3(1.0, clamp(lcol.g, 0.72, 0.98), clamp(lcol.b, 0.35, 0.90));
			lcol = mix(vec3(1.0, 0.85, 0.6), lcol, 0.3);
		}
		float hK = LIGHT_GLOW / 100.0;
		// 水面像素（colortex1.b 材质标志）：手持光弱加法提亮——
		// 不 max 覆盖（否则程序水色×albedo = 绿色纯平光罩，盖掉
		// 半透明水底透出与 SSR 反射内容）、不乘 albedo（程序水色
		// 青蓝 × 暖光 = 偏绿）。水面本身的受光由 gbuffers_water
		// calcLight 与 SSR 反射负责
		float wFlagH = texture(colortex1, texcoord).b;
		if (wFlagH > 0.5) {
			color += lcol * hatt * hK * dayW * 0.35 * (1.0 - bodyK);
		} else {
			// 材质响应：gbuffers 写入的 albedo（colortex2），与放置光源同构
			vec3 albedo = texture(colortex2, texcoord).rgb;
			// 与场景光取 max（原版 lightmap 语义：亮度 = max(天光, 方块光)）：
			// 手持光不叠加在其他光源之上——火把旁再持火把不会过曝；
			// 远处/白天场景光胜出，手持光自然退场
			color = max(color, lcol * hatt * hK * dayW * albedo * (1.0 - bodyK));
			color *= 1.0 + 0.7 * hK * dayW * bodyK;
		}
	}
	// HDR 软压缩（保色度）：diffuse ≤ 1.0（原版 lightmap 上限）线性保留，
	// 光斑亮度递减与纹理对比度原样映射；仅对 HDR 超限（太阳直射 ~1.4、
	// 萤石 emission 叠加）压缩亮度、色度比率保留。
	// 逐通道压缩会压扁色度（暖黄变白），不采用
	float lumaT = dot(color, vec3(0.2126, 0.7152, 0.0722));
	float hdrK = mix(1.0, 1.0 / max(lumaT, 1e-4), smoothstep(0.85, 1.25, lumaT));
	color *= hdrK;
	// 暗部保护：final 的暗部用弱伽马 1.4（不再线性直出），暗部不被
	// 显示器压成死黑；保护系数 25%——纯暗处压到 25% 保留轮廓层次
	// （0.35 时无光处整体抬得太平坦，均匀发亮像夜视），夜晚无光处
	// 深色 ≈0.03 可辨、浅色 ≈0.08
	float lumaDark = dot(color, vec3(0.2126, 0.7152, 0.0722));
	color *= mix(0.25, 1.0, smoothstep(0.0, 0.12, lumaDark));
	// 对比度：不再做——偏移式对比度（(x-0.5)×1.25+0.5）会把亮部
	// （>0.9）推过 1.0 再 clamp：萤石 face（light 0.94 + emission 0.45
	// ≈ 1.2）纹理差被整体压平（"萤石材质不明显"）；同时把 0.5 以下的
	// 光斑外圈压暗（0.21→0.14），加深"深阴影圈"。中段直通无对比度，
	// 用户认可中段——直出
	float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
	// 饱和度：不再做增强——HDR 软压缩是亮度/色度同比例（保色度），
	// 颜色本来就保留，不需要 Reinhard 时代的补偿。增强只会把光斑
	// 中心的热色推成高饱和（"中心颜色饱和度过高"），并把萤石 face
	// 变成 (1.0, 0.33, 0.09) 纯橙红、纹理被 clamp 压平（"萤石材质
	// 不明显"）。直出 = 三分屏中段（直通）观感
	// ===== SSR 调试可视化（临时，DEBUG_SSR=0 时编译期消除） =====
	// 1=门禁分解（R:材质标志 G:深度有效 B:深度一致，白=水面）
	// 2=screenValid（ray 在屏内） 3=hitCandidate（深度穿越候选）
	// 4=rayHit（最终命中） 5=reflectionWeight（反射权重 0~1）
	// 6=SSR 反射色（线性域） 7=colortex3 深度快照
	// 8=SSR miss（水面无任何命中 = 弱 fallback） 9=colortex1 直显
	// 10=colortex2 albedo 直显（水下水面程序归属诊断）
	if (DEBUG_SSR == 1) {
		// 门禁分解：R = 材质标志（colortex1.b，水面应=1 → 红亮）
		//           G = 水面深度有效（colortex1.r > 0.5 → 绿亮）
		//           B = depthtex0 与 colortex1.r 深度一致（→ 蓝亮）
		// 白 = 三重门禁全过（真正水面）；黑 = 非水面像素
		// （全黑且无红/绿/蓝 = 水面像素一个门禁都没过，见 debug 9）
		float m1 = (dbgWFlag > 0.5) ? 1.0 : 0.0;
		float m2 = (dbgWd > 0.05) ? 1.0 : 0.0;
		float m3 = (abs(texture(depthtex0, texcoord).r - dbgWd) < 0.001) ? 1.0 : 0.0;
		color = vec3(m1, m2, m3);
	} else if (DEBUG_SSR == 2) color = vec3(dbgSsrScreen);
	else if (DEBUG_SSR == 3) color = vec3(dbgSsrCand);
	else if (DEBUG_SSR == 4) color = vec3(dbgSsrHit);
	else if (DEBUG_SSR == 5) color = vec3(dbgSsrW);
	else if (DEBUG_SSR == 6) color = dbgSsrCol;
	else if (DEBUG_SSR == 7) {
		// 诊断：colortex3 灰度直显（0=黑 0.5=灰 1=白）。
		// 诊断期 skybasic 写 0.5（天空应=中灰）；地形深度 <1 偏白。
		// 全黑 = gbuffers 写 colortex3 完全未生效
		color = vec3(texture(colortex3, texcoord).r);
	} else if (DEBUG_SSR == 8) {
		// SSR miss：水面像素无任何命中 = 1（弱环境 fallback），
		// 命中 = 0；非水面像素恒为 0（只有水面能进入 SSR）
		color = vec3(dbgSsrMiss);
	} else if (DEBUG_SSR == 9) {
		// 诊断：colortex1 直显——R = b 通道（水面材质标志，水面应
		// =1 纯红）、G = r 通道（水面深度灰度，远处偏亮）。水面
		// 像素若为黑 = gbuffers_water 写 colortex1 完全未生效
		color = vec3(texture(colortex1, texcoord).b, texture(colortex1, texcoord).r, 0.0);
	} else if (DEBUG_SSR == 11) {
		// 诊断：shadowtex0 直显（阴影图灰度，近太阳亮/远太阳暗）。
		// 全白/全黑 = shadow pass 未渲染几何（阴影图空）；有明暗
		// 层次 = 阴影图正常（问题在 shadowSample 或强度）
		color = vec3(texture(shadowtex0, texcoord).r);
	} else if (DEBUG_SSR == 10) {
		// 诊断：colortex2 直显（gbuffers 写入的 albedo 灰度）。
		// 水下视角看水面：水面区域若为亮色（原版水纹理色）=
		// 该渲染走了带纹理采样的程序（非 gbuffers_water 程序色
		// 0.30/0.50/0.62，灰度 ≈0.44）
		color = vec3(texture(colortex2, texcoord).r);
	}
	fragOut0 = vec4(color, 1.0);
}
