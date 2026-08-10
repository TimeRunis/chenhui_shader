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

// colortex0（gbuffers 主颜色 + alpha 方块光等级）用半浮点：
// RGBA8 下 PRE_EXPOSURE 0.62 把漫反射量化精度砍掉 40%，圆石细颗粒
// 纹理差（0.02~0.056）被量化压平（"材质被光照压住"）；16F 下
// 纹值无损往返，HDR 高光（萤石 emission）也精确存储。
// 声明包在块注释里：Iris 加载器识别 /* */ 内的格式 directive，
// 裸声明在 Iris 1.7 会原样进入 GLSL 编译（RGBA16F 未定义 → C1503）
/*
const int colortex0Format = RGBA16F;
const int colortex1Format = RGBA16F;
const int colortex2Format = RGBA16F;
*/

#include "/lib/common.fsh"
#include "/lib/noise.glsl"
#include "/lib/sky.glsl"
#include "/lib/water.glsl"

uniform sampler2D gcolor;
uniform sampler2D depthtex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2; // gbuffers 材质 albedo（手持光源材质响应）

// Iris 支持的 OptiFine 兼容 uniform：主手/副手手持方块的光照等级
// （0~15，火把 14、萤石/灯笼 15、空手 0）。uniform 全局共享，
// gbuffers_hand 无需中转，composite 直接读取驱动手持光源
uniform int heldBlockLightValue;
uniform int heldBlockLightValue2;

out vec4 fragOut0;

void main() {
	float d = texture(depthtex0, texcoord).r;
	vec3 color = texture(gcolor, texcoord).rgb;
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
	// gbuffers_water 把水面 alpha 恒写 0.82。识别 = alpha∈(0.80,0.84)
	// + 反射方向朝下（R.y<−0.05）排除墙面光源（视线平视、反射不朝下），
	// + 4 邻居 alpha 一致性排除地面光源误判：方块光 13 级
	// （blockSourceLevel 恰为 0.82）周围 alpha 渐变（0.94/0.88/0.76），
	// 而水面大片恒定 0.82——俯视萤石旁 2 格不会触发反射。
	// 反射色采样自 colortex0（gbuffers 原始预曝光域），×1/PRE_EXPOSURE
	// 恢复到与 color 同域，随主管线一起过 HDR 压缩与暗部保护。
	// 未命中/出屏回退天空色（与主天空同一函数同一雾混合），
	// 命中点再按距离补雾——远岸山体反射不会突兀清晰
	{
		float aB = texture(gcolor, texcoord).a;
		if (aB > 0.80 && aB < 0.84 && WATER_REFLECT > 0) {
			// 水面深度从 colortex1（gbuffers_water 写入）取，不用 depthtex0：
			// 半透明水面不写主深度缓冲，depthtex0 在水面像素处是
			// 水底/天空的深度——用它重建反射起点会错位（岸上看水起点
			// 沉到水底 → 反射内容整体错位；水下抬头起点飞到天顶
			// 远平面 → 采样到未写入的天空像素 = 黑色 = "负片"）。
			// 其他像素 colortex1 未写（0），阈值 0.5 排除
			float wd = texture(colortex1, texcoord).r;
			if (wd > 0.5) {
			float d = wd;
			vec3 vp = viewPosFromDepth(d, texcoord);
			vec3 viewDir = normalize(vp);
			// 世界位置 → 同一水面波浪法线（与 gbuffers_water 同函数，
			// 波纹随时间流动，反射方向逐帧变化 = 涟漪自然晃动）
			vec3 nV = normalize(mat3(gbufferModelView)
				* waterNormalWorld(worldPosFromView(vp),
					(WAVE_AMOUNT / 100.0) * 0.35 * (1.0 + wetness * 1.2)));
			vec3 R = reflect(viewDir, nV);
			// 不限制反射方向：平视/微俯看远处水面时反射方向朝上
			// （反射天空、远岸山体）——这是水面反射最常见的场景，
			// 之前限定 R.y<−0.05 把它全部排除 = 用户看到"几乎原版水"
			// 的根因。方块光 13 级误判已由 4 邻居 alpha 一致性排除
			{
				vec2 pxR = vec2(1.0 / viewWidth, 1.0 / viewHeight);
				float aN = 0.0;
				aN += abs(texture(gcolor, texcoord + vec2(pxR.x, 0.0)).a - 0.82);
				aN += abs(texture(gcolor, texcoord - vec2(pxR.x, 0.0)).a - 0.82);
				aN += abs(texture(gcolor, texcoord + vec2(0.0, pxR.y)).a - 0.82);
				aN += abs(texture(gcolor, texcoord - vec2(0.0, pxR.y)).a - 0.82);
				if (aN < 0.1) {
					vec3 Rn = normalize(R);
					vec3 Rw = normalize(mat3(gbufferModelViewInverse) * Rn);
					// 反射天空（回退）：与主天空同参数同雾混合——
					// 地平线方向混雾色，反射的天际线不出现亮白带
					vec3 refl = getSkyColor(Rw, STARS / 100.0, SUN_GLOW / 100.0, SUN_SIZE / 100.0, MOON_SIZE / 100.0, STAR_DENSITY / 100.0, float(CLOUDS), float(CLOUD_DENSITY) / 100.0);
					float hzR = pow(max(1.0 - Rw.y, 0.0), 2.5);
					refl = mix(refl, fogC, hzR * 0.45);
					// 光线步进：对数步长（近处密、远处疏，视空间均匀）；
					// 命中判据 = 射线线性深度越过表面深度（diff 由负变正
					// = 穿入表面）。跨越判定无容差参数、远近一致——固定
					// 容差在远处 linDepth 膨胀（0.03/格）后永远命中不了，
					// 远岸/山体反射全部失效。
					// 步数/范围：低 16 步 ≈ 330 格、高 20 步 ≈ 640 格——
					// 覆盖对岸/山体反射。ray 沿水面方向前进时水面区域
					// 永不命中（depthtex0 里是水底，深于射线），只有走到
					// 岸边/对岸才命中——范围不足 = 深水区只剩天空。
					// 高档（2）两遍不同相位步进取平均 → 波纹亚步长模糊
					int steps = (WATER_REFLECT > 1) ? 20 : 16;
					float startT = (WATER_REFLECT > 1) ? 0.45 : 0.4;
					vec3 acc = vec3(0.0);
					bool hit = false;
					for (int k = 0; k < ((WATER_REFLECT > 1) ? 2 : 1); k++) {
						float t = (k == 1) ? startT * 1.35 : 0.0;
						vec3 col = refl;
						bool skipFirst = true;
						// 上一跳状态（命中插值用）：大步长命中时在上一跳与
						// 当前跳之间按深度差线性插值交点——消除反射内容
						// 像素级错位（旧版直接取大步长采样点 = 反射扭曲）
						vec2 suvPrev = vec2(0.0);
						float pPrevLin = 0.0;
						float hPrevLin = 0.0;
						for (int i = 0; i < steps; i++) {
							t += t * 0.42 + startT;
							vec3 p = vp + R * t;
							vec4 clip = gbufferProjection * vec4(p, 1.0);
							if (clip.w <= 0.0) break;
							vec2 suv = clip.xy / clip.w * 0.5 + 0.5;
							// 出屏：clamp 沿屏幕边缘继续 march——低头时 ray 朝上
							// 滑过顶缘地平线带（建筑物反射保留，大步长不再跳过
							// 地平线内容 = "影子从顶部消失"），潜水时沿底缘
							// 水底延续。边缘像素深度 = 天空（远平面）时取该
							// 像素已渲染颜色回退（含雾/日月/云，零额外成本；
							// 旧版每像素调 getSkyColor/overworldSky 含体积云
							// ray march = 低头全屏水面掉帧 + 全屏取同一条
							// 顶缘窄带 = 细条拉伸）
							if (suv.x < 0.001 || suv.x > 0.999 || suv.y < 0.001 || suv.y > 0.999) {
								vec2 cSuv = clamp(suv, 0.0, 1.0);
								if (linDepth(texture(depthtex0, cSuv).r) > 400.0) {
									col = texture(gcolor, cSuv).rgb * (1.0 / PRE_EXPOSURE);
									break;
								}
								suv = cSuv;
							}
							float pLin = linDepth(clip.z / clip.w * 0.5 + 0.5);
							float hitLin = linDepth(texture(depthtex0, suv).r);
							// 第一跳跳过（射线紧贴水面自身表面，diff≈0
							// 会误命中自己）
							if (skipFirst) { skipFirst = false; suvPrev = suv; pPrevLin = pLin; hPrevLin = hitLin; continue; }
							if (pLin - hitLin > 0.0) {
								// 命中插值：未命中（diff<0）→ 命中（diff>0）
								// 的零点（假设深度在跳间线性变化）
								float diffN = (pPrevLin - hPrevLin) - (pLin - hitLin);
								if (diffN > 1e-6) {
									float f = clamp((pPrevLin - hPrevLin) / diffN, 0.0, 1.0);
									suv = mix(suvPrev, suv, f);
								}
								col = texture(gcolor, suv).rgb * (1.0 / PRE_EXPOSURE);
								// 反射点距离雾：与主场景同参（fogEnd 80% 起，
								// 90%~100% 视距边缘补满到 1.0——反射点越过
								// 视距边缘时同样融入雾色，不产生锐利边界）
								float fogEdge = smoothstep(fogEnd * 0.9, fogEnd, t);
								float fogF = mix(smoothstep(fogEnd * 0.8, fogEnd, t) * fogAmt, 1.0, fogEdge);
								col = mix(col, fogC, fogF);
								hit = true;
								break;
							}
							suvPrev = suv; pPrevLin = pLin; hPrevLin = hitLin;
						}
						acc += col;
					}
					refl = acc / float((WATER_REFLECT > 1) ? 2 : 1);
					// 太阳镜面高光（波光粼粼）：反射方向对准太阳时点亮点，
					// 随波浪法线晃动；夜晚弱化只留月光
					refl += vec3(1.0, 0.8, 0.55)
						* pow(max(dot(Rn, sunDirV()), 0.0), 350.0) * (0.15 + 0.85 * dfFog);
					// 菲涅尔反射率：俯视 0.45、掠射 0.9（用户选择增强——
					// 俯视时附近方块/光源/日月反射明显可见，掠射近全反射）
					float reflK = 0.45 + 0.45 * pow(1.0 - dot(-viewDir, nV), 3.0);
					// 未命中（纯天空/屏幕边缘回退）时减权：深水大湖中心
					// 反射 ray 范围内无物体，全量反射亮白天空会让透过水面的
					// 海带/水底发白；命中实体/太阳时保持全量
					if (!hit) reflK *= 0.55;
					color = mix(color, refl, reflK);
				}
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
		float hatt = clamp((rad - hd) / rad, 0.0, 1.0);
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
				vec3 lc = texture(colortex1, off).rgb;
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
			// 再向暖白收敛 40%：火焰动画帧/采样抖动造成的色相漂移被
			// 压掉，不偶发变红；火把橙、萤石白、海晶灯蓝白仍在带内
			lcol = vec3(1.0, clamp(lcol.g, 0.72, 0.98), clamp(lcol.b, 0.35, 0.90));
			lcol = mix(vec3(1.0, 0.85, 0.6), lcol, 0.6);
		}
		// 材质响应：gbuffers 写入的 albedo（colortex2），与放置光源同构
		vec3 albedo = texture(colortex2, texcoord).rgb;
		float hK = LIGHT_GLOW / 100.0;
		// 与场景光取 max（原版 lightmap 语义：亮度 = max(天光, 方块光)）：
		// 手持光不叠加在其他光源之上——火把旁再持火把不会过曝；
		// 远处/白天场景光胜出，手持光自然退场
		color = max(color, lcol * hatt * hK * dayW * albedo * (1.0 - bodyK));
		color *= 1.0 + 0.7 * hK * dayW * bodyK;
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
	fragOut0 = vec4(color, 1.0);
}
