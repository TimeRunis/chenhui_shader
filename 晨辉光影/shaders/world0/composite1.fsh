#version 450 compatibility

in vec2 texcoord;

// ===== 晨辉光影 选项（各文件定义必须完全一致） =====
#define CLOUDS 2 // 体积云 [0 1 2 3]
#define CLOUD_SHADOW 40 // 云影强度 [0 20 40 60 80 100]
#define WATER_REFLECT 1 // 水面反射 [0 1 2]
#define LIGHT_GLOW 60 // 动态光源强度 [0 20 40 60 80 100]
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
*/

#include "/lib/common.fsh"
#include "/lib/noise.glsl"
#include "/lib/sky.glsl"

uniform sampler2D gcolor;
uniform sampler2D depthtex0;

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
		color = getSkyColor(worldDir, STARS / 100.0, SUN_GLOW / 100.0, SUN_SIZE / 100.0, MOON_SIZE / 100.0, STAR_DENSITY / 100.0);
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
		// 颜色用大气散射渐变 fogC（天顶蓝/地平线冷蓝或暖白）
		float fogF = smoothstep(fogEnd * 0.8, fogEnd, dist) * fogAmt;
		color = mix(color, fogC, fogF);
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
