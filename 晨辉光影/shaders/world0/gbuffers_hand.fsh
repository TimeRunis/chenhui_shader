#version 450 compatibility
/* RENDERTARGETS: 0,1,2 */

uniform sampler2D texture;
uniform sampler2D specular;

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

#include "/lib/common.fsh"
uniform float alphaTestRef;

// Iris 支持的 OptiFine 兼容 uniform：主手/副手手持方块的光照等级
// （0~15，火把 14、萤石/灯笼 15、空手 0）
uniform int heldBlockLightValue;
uniform int heldBlockLightValue2;

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
	vec3 n = normalize(normal);
	vec3 viewDir = normalize(viewPos);
	// 手持方块支持 PBR 光滑度与自发光（无切线，细节法线略过）
	vec4 sp = texture(specular, texcoord);
	float smoothness = sp.r;
	float metal = clamp(sp.g / 229.0, 0.0, 1.0);
	float emissive = sp.a;
	if (emissive > 0.999) {
		emissive = 0.0;
		// 无 LabPBR specular 贴图（默认全白）＝原版哑光材质：
		// smoothness 压到 0.15，消除太阳方向整片泛白高光
		smoothness = min(smoothness, 0.15);
	}
	vec3 color = calcLight(albedo, n, lmcoord, viewDir, worldPos, smoothness, metal, emissive, SHADOW_QUALITY);
	fragOut0 = vec4(color * PRE_EXPOSURE, blockSourceLevel(lmcoord));
	fragOut2 = vec4(albedo, 1.0);
	// 手持光源材质色写入 colortex1（composite1 物品区域采样取光源色，
	// 采样用 .rga 通道）：r/g/a = albedo×等级——火把=暖橙、萤石=白、
	// 灯笼=橙、海晶灯=蓝白，随手持物品变化；非光源物品写 0。
	// b = 0 显式清水面材质标志（手持物品不是水面；colortex1.b=1 只
	// 由 gbuffers_water 写，见 composite1 注释）
	float handLvl = max(float(heldBlockLightValue), float(heldBlockLightValue2));
	fragOut1 = vec4(albedo.rg * clamp(handLvl, 0.0, 1.0), 0.0, albedo.b * clamp(handLvl, 0.0, 1.0));
}
