#version 450 compatibility
/* RENDERTARGETS: 0,1,2 */
// 流体通道：水面（波浪+反射标记）与岩浆（自发光+光源标记）
// 岩浆用颜色启发式识别（橙红 vs 蓝绿），不依赖方块 ID 属性

uniform sampler2D texture;

in vec4 tint;
in vec2 texcoord;
in vec2 lightUV;
in vec3 minecraftPos;
in vec3 viewPos;
in vec3 normalV;

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
#define SUN_STRENGTH 100 // 太阳光强度 [[25 50 75 100 125 150 175 200]]
#define MOON_STRENGTH 1000 // 月光强度 [0 100 200 300 400 500 600 750 1000 1250 1500 1750 2000]

#include "/lib/common.fsh"
uniform float alphaTestRef;

#include "/lib/noise.glsl"
#include "/lib/water.glsl"

layout(location = 0) out vec4 fragOut0;
layout(location = 2) out vec4 fragOut2;
layout(location = 1) out vec4 fragOut1;

void main() {
	// 几何法线(顶点着色器从 gl_Normal 变换到眼空间);
	// 无法线属性的程序 gl_Normal=0 → 回退朝上,不破坏兼容
	vec3 normal = normalize(normalV);
	if (length(normalV) < 0.001) normal = vec3(0.0, 1.0, 0.0);
	vec3 worldPos = minecraftPos;
	vec2 lmcoord = lightUV;
	vec4 vertexColor = tint;
	vec4 albedo4 = texture(texture, texcoord) * vertexColor;
	if (albedo4.a < alphaTestRef) discard;

	vec3 albedo = albedo4.rgb;
	float alpha = albedo4.a;
	vec3 viewDir = normalize(viewPos);

	// 岩浆识别（颜色启发式：橙红 r 显著大于蓝 b，且足够亮）
	bool isLava = (albedo.r > albedo.b * 1.5) && (albedo.r > 0.22);

	vec3 n = normalize(normal);
	if (isLava) {
		// 岩浆：自发光橙色 + 表面涌动闪烁
		float flick = 0.8 + 0.2 * hash1(floor(frameTimeCounter * 12.0) + floor(worldPos.y * 2.0));
		vec3 color = albedo * (0.55 + 0.85 * flick) + vec3(0.6, 0.2, 0.02) * flick * 3.2;
		fragOut0 = vec4(color * PRE_EXPOSURE, blockSourceLevel(lmcoord));
		fragOut1 = vec4(0.0, 0.0, 0.0, 1.0); // 非水面：岩浆清材质标志（colortex1.b=0）
		return;
	}

	// 水下植物（海带/海草等 translucent 植物）区分：几何法线近水平
	// （柱面侧面），与水面（法线朝上）不同。植物不是水面——普通
	// 光照、alpha 用纹理值、不写 colortex1 水面深度；否则海带被当
	// 水面写深度 + alpha 0.65 → composite1 把它识别为水面并执行
	// SSR（"海带发白/海带出现在反射里"的根因，debug 模式 1 里
	// 海带显示为白色 mask）。
	// 注意：水下抬头看水面时，水面法线在视空间同样 n.y≈0（世界
	// 朝上 ≈ 视空间 -forward）——旧分支会把水面当植物渲染成原版
	// 纹理（程序色替换在分支之后）= "水底看水面是原版材质"的根因。
	// 加蓝色水纹理检测：水（蓝主导）走水面分支，海带（绿）仍走
	// 植物分支
	if (n.y < 0.5 && !(albedo.b > albedo.r * 1.5 && albedo.b > 0.3
	                  && albedo.r < 0.45 && albedo.g < 0.7)) {
		vec3 colorP = calcLight(albedo, n, lmcoord, viewDir, worldPos, 0.5, 0.0, 0.0, SHADOW_QUALITY);
		fragOut0 = vec4(colorP * PRE_EXPOSURE, alpha);
		fragOut2 = vec4(albedo, 1.0);
		// 不写水面深度/材质标志：海带不是水面（colortex1 = 0，SSR 不参与；
		// a=1 保证 blend 下也把背景水面标志清掉）
		fragOut1 = vec4(0.0, 0.0, 0.0, 1.0);
		return;
	}

	// 水面：不使用原版水纹理材质——水面颜色由光影程序化控制
	// （亮蓝基础色；光照/波纹/反射/波光全部来自光影本身。
	// 0.30/0.50/0.62 的 B/G=1.24 偏绿——暗部观感"深绿"（用户
	// 反馈：平视全深绿）；0.30/0.48/0.72 的 B/G=1.5 明显更蓝，
	// 亮度保持原级，平视/俯视的水色都呈蓝调）
	albedo = vec3(0.30, 0.48, 0.72);
	// 水面：波浪法线（与 composite1 的 SSR 共用同一函数）。
	// 振幅系数 0.9（0.35→0.6→0.9：所有水面的波纹都要可见，
	// 不只是 SSR 反射区域——波浪法线倾斜让水面明暗与高光
	// 波纹遍布整片水面；密度对齐 Derivative Main 4 层高频波）
	float amp = (WAVE_AMOUNT / 100.0) * 0.35 * (1.0 + wetness * 1.2);
	vec3 wn = waterNormalWorld(worldPos, amp);
	// 雨打水面（参考 Derivative Main RainEffect.glsl 的雨法线扰动）：
	// 湿天水面叠加高频快速变化的雨纹——雨点落下产生细碎波纹，
	// 水面法线高频抖动（波纹更碎、反射与波光破碎闪烁）
	if (wetness > 0.02) {
		float t = frameTimeCounter * 6.0;
		vec2 rq = worldPos.xz * 1.2 + vec2(t * 0.4, t * 0.3);
		float rn = noise2(rq) + 0.5 * noise2(rq * 2.3 - vec2(t * 0.6, 0.0));
		// 扰动幅度随雨量（wetness），两层噪声叠加高频雨纹
		vec3 rp = vec3((rn - 0.75) * 1.6 * wetness, 1.0, (rn - 0.75) * 1.6 * wetness);
		wn = normalize(wn + rp * 0.8);
	}
	n = normalize(mat3(gbufferModelView) * wn);

	// 水面基础色不再压暗（旧版 ×0.4 是"反射率"设计残留：程序水色
	// 时代它把白天水面压回 (0.12,0.20,0.25) 暗色 = "发黑/深绿"根因
	// 之一）。水面颜色 = 程序水色 × 光照，夜晚由天光自然压暗
	float df = dayFactorF();
	vec3 color = calcLight(albedo, n, lmcoord, viewDir, worldPos, 0.92, 0.0, 0.0, SHADOW_QUALITY);

	// 水面 alpha = 0.0（Derivative 式）：水色不再写入 gbuffer，水面
	// 像素 = 水底颜色 100% 透出。水体透明度改由 composite1 按水深
	// 指数混合（浅水全透、深水渐变为水色），不再全局常数 alpha
	// （原 0.325/0.65）
	fragOut0 = vec4(color * PRE_EXPOSURE, 0.0);
	fragOut2 = vec4(albedo, 1.0);
	// 水面深度 + 材质标志写入 colortex1：
	// r = 水面片元深度（非线性 d，composite1 的 SSR 用它重建反射起点
	// ——depthtex0 在半透明水面处是水底/天空的深度，不能用于水面
	// 反射起点）；b = 1.0 水面材质标志（composite1 的 SSR 用它识别
	// 水面；其余所有 gbuffers 程序显式写 0，a=1 保证 blend 下覆盖）
	fragOut1 = vec4(gl_FragCoord.z, 0.0, 1.0, 1.0);
}
