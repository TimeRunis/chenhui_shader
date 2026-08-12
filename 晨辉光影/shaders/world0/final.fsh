#version 450 compatibility

in vec2 texcoord;

uniform sampler2D gcolor;

out vec4 fragOut0;

void main() {
	vec3 color = texture(gcolor, texcoord).rgb;
	// 纯线性直出（灰白膜修复）：旧版按亮度分段的伽马抬升（luma
	// 0.06~0.35 → gamma 1.4）把光斑衰减带（中间亮度）压平抬亮成
	// 灰带——"非最高光照区灰白膜"的根因（实验确认：关闭后光斑
	// 恢复自然连续渐变，白天/夜晚均正常）。渲染管线保持线性，
	// 亮度重塑不做分段处理
	fragOut0 = vec4(color, 1.0);
}
