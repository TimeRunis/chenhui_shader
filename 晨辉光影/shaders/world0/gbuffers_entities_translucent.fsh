#version 450 compatibility
/* RENDERTARGETS: 0,1,2 */
// 透明实体通道（entityTranslucent：玩家皮肤透明层、盔甲等）：
// Iris 对 translucent 程序默认开启 blend → alpha 混合。
// 与不透明 gbuffers_entities 的差异：
// ① alpha = 贴图 alpha（半透明层正确混合）——不透明实体的
//    blockSourceLevel 标记不适用（blend 下 alpha=0 会整层透明）；
// ② 不 alphaTest 剔除：透明像素（alpha=0）混合后 = 背景，无需
//    剔除；半透明像素（0<alpha<1）必须保留（"皮肤透明通道没
//    渲染"根因：旧逻辑走不透明 entities，alphaTest 把 alpha<0.1
//    的透明层剔成空洞）；
// ③ 不写 colortex3（半透明不参与 SSR 场景深度——SSR 穿过半透明
//    实体，反射内容不被半透明层阻挡）；
// ④ colortex1.b 清水面材质标志（a=1 保证 blend 下也覆盖）

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

layout(location = 0) out vec4 fragOut0;
layout(location = 2) out vec4 fragOut2;
layout(location = 1) out vec4 fragOut1; // colortex1.b 水面材质标志（非水面 = 0）

void main() {
	fragOut1 = vec4(0.0, 0.0, 0.0, 1.0); // 非水面：colortex1.b 显式清零
	// 几何法线（顶点着色器从 gl_Normal 变换到眼空间）；
	// 无法线属性的程序 gl_Normal=0 → 回退朝上，不破坏兼容
	vec3 normal = normalize(normalV);
	if (length(normalV) < 0.001) normal = vec3(0.0, 1.0, 0.0);
	vec3 worldPos = minecraftPos;
	vec2 lmcoord = lightUV;
	vec4 vertexColor = tint;
	vec4 albedo4 = texture(texture, texcoord) * vertexColor;

	vec3 albedo = albedo4.rgb;
	float alpha = albedo4.a;
	vec3 n = normalize(normal);
	vec3 viewDir = normalize(viewPos);
	vec3 color = calcLight(albedo, n, lmcoord, viewDir, worldPos, 0.12, 0.0, 0.0, SHADOW_QUALITY);
	// alpha = 贴图 alpha：blend 下半透明层正确混合（原版 entityTranslucent 语义）
	fragOut0 = vec4(color * PRE_EXPOSURE, alpha);
	fragOut2 = vec4(albedo, 1.0);
}
