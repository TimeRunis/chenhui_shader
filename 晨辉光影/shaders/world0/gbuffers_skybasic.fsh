#version 450 compatibility
/* RENDERTARGETS: 0,1,2,3 */
// 原版天空渐变透传 + 固定远平面深度（保证 isSky 判定可靠）
// colortex3 = 天空深度 = 1.0（远平面；location1/2 无输出变量，
// Iris 不写 colortex1/2）。RENDERTARGETS 是位置对应：第 i 位 =
// location i 输出的 buffer——旧写法「0,3」把 colortex3 绑到了
// location1（无输出），天空深度从未写入（灰度诊断全黑）

in vec4 tint;

layout(location = 0) out vec4 fragOut0;
layout(location = 3) out vec4 fragOut3; // colortex3：r=深度（天空=远平面），gba 无内容
layout(location = 1) out vec4 fragOut1; // colortex1.b 水面材质标志（非水面 = 0）

void main() {
	gl_FragDepth = 1.0;
	fragOut3 = vec4(1.0, 0.0, 0.0, 0.0);
	fragOut1 = vec4(0.0, 0.0, 0.0, 1.0); // 非水面：天空也显式清材质标志
	fragOut0 = gl_Color;
}
