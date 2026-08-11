#version 450 compatibility
/* RENDERTARGETS: 0,1,2,3 */
/* BLEND: SOURCE_ALPHA, ONE_MINUS_SOURCE_ALPHA */
// MC 半透明粒子队列（PARTICLE_SHEET_TRANSLUCENT：篝火烟/烟雾等）
// 专用程序——Iris 1.7 把粒子分两队列：普通粒子 → gbuffers_particles、
// 半透明粒子 → 本程序。没有本程序时烟 fallback 到 gbuffers_basic，
// "烟被刷天空色"从未被修复（gbuffers_particles 不在 fallback 链）。
// 内容与 gbuffers_particles 完全相同（半透明混合 + 原版式 lightmap
// 光照 + 粒子深度写 colortex3 供 composite 区分粒子与天空）。
// 粒子（篝火烟/烟雾/火花/树叶等）专用半透明渲染。
// 没有此程序时粒子 fallback 到 gbuffers_basic，而 basic 是不透明
// 程序（默认 GL_ONE/GL_ZERO 直接覆盖、alpha 输出方块光等级）→
// 半透明烟粒子被渲染成实心色块，且夜晚/阴影下 calcLight 把光照压
// 到接近 0（"烟后天空呈黑色"的根因）。本程序：
// ① 半透明混合 + 输出粒子真实 alpha——烟透出背景，不再实心盖黑；
// ② 光照用原版式 lightmap 乘法（albedo × r 通道显示亮度）：夜晚
// 月光下烟 = 灰 × 0.2~0.4（可见的暗灰，气体不该被压成全黑），
// 白天 = 满亮，篝火旁方块光自动补足——不用 calcLight 的夜晚/阴影
// 衰减（那是为固体方块设计的）；
// ③ 粒子深度写 colortex3（第 3 渲染目标）：粒子不写深度缓冲（MC
// 粒子 depthMask=false，Iris 没有 DEPTHWRITE 程序属性），composite
// 在粒子像素处读到 depthtex0 = 背景天空 1.0 → 把烟误判成天空刷成
// 天幕色（"烟随机变浅蓝/烟柱被方块遮挡"的根因）。colortex3 是自
// 定义渲染目标不受 depthMask 限制，composite 检测「depthtex0 是天
// 空但 colortex3 有非天空深度」= 粒子盖在天空上 → 用粒子深度，
// 天空判定与雾距离随之正确。副作用：烟进入 SSR 场景深度 → 水面
// 倒影里出现烟的轮廓（物理正确，烟雾本来就该被倒映）

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
layout(location = 3) out float depthOut; // colortex3 粒子深度（composite 区分粒子与天空用）
layout(location = 1) out vec4 fragOut1; // colortex1.b 水面材质标志（非水面 = 0）

void main() {
	vec4 albedo4 = texture(texture, texcoord) * tint;
	if (albedo4.a < alphaTestRef) discard;
	depthOut = gl_FragCoord.z;
	fragOut1 = vec4(0.0, 0.0, 0.0, 1.0); // 非水面：粒子显式清材质标志（a=1 保证 blend 下也覆盖）

	// 原版粒子观感：albedo × lightmap 显示亮度（r = max(天光, 方块光)）。
	// clamp 到格中心范围（同 calcLight 的 lmMin/lmMax，避免采样到
	// 0 级格之外）
	const vec2 lmMin = vec2(0.5 / 16.0);
	const vec2 lmMax = vec2(15.5 / 16.0);
	float lm = texture(lightmap, clamp(lightUV, lmMin, lmMax)).r;

	// 烟偏实：输出 alpha 提高（×1.5）。半透明烟在 alpha 低处
	// （粒子生命周期淡出 + 纹理边缘渐变）混合后背景蓝占主导 =
	// "烟随机变蓝"的根因——烟是散射体，密度高处应接近不透明
	// 灰白。颜色保持 albedo × lightmap（灰白/夜晚暗灰）
	vec3 color = albedo4.rgb * lm;
	float alpha = clamp(albedo4.a * 1.5, 0.0, 1.0);

	// 半透明输出：alpha = 粒子纹理 alpha（blend 用），
	// 颜色 = 光照后的灰烟 × PRE_EXPOSURE（与主管线同域）
	fragOut0 = vec4(color * PRE_EXPOSURE, alpha);
}
