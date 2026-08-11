#version 450 compatibility
/* RENDERTARGETS: 0,1,2,3 */

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

#include "/lib/common.fsh"
uniform float alphaTestRef;


layout(location = 0) out vec4 fragOut0;
layout(location = 2) out vec4 fragOut2;
layout(location = 3) out float depthOut; // colortex3 不透明深度（SSR scene depth）
void main() {
	// 不透明深度快照：几何深度写入 colortex3（SSR 用；水面/雨/云/粒子/手持等半透明程序不写，水面像素处保留水底/地形深度）
	depthOut = gl_FragCoord.z;
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
	vec3 color = calcLight(albedo, n, lmcoord, viewDir, worldPos, 0.1, 0.0, 0.0, SHADOW_QUALITY);
	fragOut0 = vec4(color * PRE_EXPOSURE, blockSourceLevel(lmcoord));
	fragOut2 = vec4(albedo, 1.0);
}
