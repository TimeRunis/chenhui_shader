#version 450 compatibility
in vec3 normalV;

// 丢弃原版云层（体积云在 composite1 程序化渲染）
void main() {
	// 几何法线(顶点着色器从 gl_Normal 变换到眼空间);
	// 无法线属性的程序 gl_Normal=0 → 回退朝上,不破坏兼容
	vec3 normal = normalize(normalV);
	if (length(normalV) < 0.001) normal = vec3(0.0, 1.0, 0.0);
discard;
}
