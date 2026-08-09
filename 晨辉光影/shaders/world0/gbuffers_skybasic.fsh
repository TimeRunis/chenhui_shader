#version 450 compatibility

// 原版天空渐变透传 + 固定远平面深度（保证 isSky 判定可靠）

in vec4 tint;

layout(location = 0) out vec4 fragOut0;

void main() {
	gl_FragDepth = 1.0;
	fragOut0 = gl_Color;
}
