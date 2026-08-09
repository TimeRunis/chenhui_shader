#version 450 compatibility

uniform sampler2D texture;

in vec4 tint;
in vec2 texcoord;
in vec2 lightUV;
in vec3 minecraftPos;
in vec3 viewPos;
in vec3 normalV;

layout(location = 0) out vec4 fragOut0;
void main() {
	// 几何法线(顶点着色器从 gl_Normal 变换到眼空间);
	// 无法线属性的程序 gl_Normal=0 → 回退朝上,不破坏兼容
	vec3 normal = normalize(normalV);
	if (length(normalV) < 0.001) normal = vec3(0.0, 1.0, 0.0);
	vec2 lmcoord = lightUV;
	vec4 vertexColor = tint;
	vec4 c = texture(texture, texcoord) * vertexColor;
	c.rgb *= vec3(1.02, 1.05, 1.12);   // 雨滴微蓝
	// 预曝光（同 PRE_EXPOSURE 0.62，本文件未 include common.fsh）：
	// 防白色雨雪/粒子在 RGBA8 输出上高光溢出
	fragOut0 = vec4(c.rgb * 0.62, c.a);
}
