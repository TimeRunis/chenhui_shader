#version 450 compatibility

in vec2 texcoord;

uniform sampler2D gcolor;

out vec4 fragOut0;

void main() {
	vec3 color = texture(gcolor, texcoord).rgb;
	// 伽马校正（暗部弱校正 / 中间亮部线性）：
	// 任何 pow < 1 的 gamma 都会把中间调压平——光源光斑内部的亮度
	// 递减（0.88→0.79→0.67）经 gamma 1.8 只剩 0.05 差，"光照没有递减、
	// 边缘突然下降"的根因之二。改为：暗部（<0.06）用弱 gamma 1.4
	// （0.01→0.04 可辨，夜晚暗部仍可见）；亮部（>0.35）线性直出，
	// 光斑递减/白天纹理原样保留；0.06~0.35 平滑过渡
	float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
	vec3 gDark = pow(max(color, 0.0), vec3(1.0 / 1.4));
	color = mix(gDark, color, smoothstep(0.06, 0.35, luma));
	fragOut0 = vec4(color, 1.0);
}
