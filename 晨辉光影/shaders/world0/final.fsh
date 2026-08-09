#version 450 compatibility

in vec2 texcoord;

uniform sampler2D gcolor;

out vec4 fragOut0;

void main() {
	vec3 color = texture(gcolor, texcoord).rgb;
	// MC 管线为伽马空间，直接输出
	fragOut0 = vec4(color, 1.0);
}
