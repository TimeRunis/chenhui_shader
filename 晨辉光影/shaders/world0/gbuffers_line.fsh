#version 450 compatibility
in vec3 normalV;


layout(location = 0) out vec4 fragOut0;
void main() {
	// 几何法线(顶点着色器从 gl_Normal 变换到眼空间);
	// 无法线属性的程序 gl_Normal=0 → 回退朝上,不破坏兼容
	vec3 normal = normalize(normalV);
	if (length(normalV) < 0.001) normal = vec3(0.0, 1.0, 0.0);
fragOut0 = gl_Color;
}
