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
#define CLOUDS 1 // 体积云 [0 1 2]
#define CLOUD_DENSITY 75 // 云密度 [50 75 100 125 150 175 200]
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
#include "/lib/noise.glsl"
#include "/lib/sky.glsl"
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
	// PBR 环境反射（金属/光滑表面反射天空穹顶——近似环境反射）：
	// 反射方向 = 视线关于法线的镜像（世界空间），采样程序化天空
	// （传 cloudLevel=0：云不参与反射且零开销）。强度 = smoothness
	// × 金属系数——LabPBR 光滑/金属方块有明显环境反射，哑光微弱
	if (smoothness > 0.1) {
		vec3 rvN = normalize(mat3(gbufferModelViewInverse) * reflect(viewDir, n));
		vec3 skyRefl = getSkyColor(rvN, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
		color += skyRefl * smoothness * mix(0.12, 0.45, metal);
	}
	fragOut0 = vec4(color * PRE_EXPOSURE, blockSourceLevel(lmcoord));
	fragOut2 = vec4(albedo, 1.0);
	// 手持光源颜色已与点光源统一（composite1 直接用 BLOCK_LIGHT_COLOR，
	// 不再采样物品材质）——colortex1 的 r/g/a 不再写手持光源数据。
	// b = 0 显式清水面材质标志（手持物品不是水面；colortex1.b=1 只
	// 由 gbuffers_water 写，见 composite1 注释）
	fragOut1 = vec4(0.0, 0.0, 0.0, 1.0);
}
