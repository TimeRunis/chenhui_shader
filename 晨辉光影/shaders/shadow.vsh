#version 450 compatibility
// 阴影 pass 顶点着色器（Derivative Main shadow.vsh 同款写法）：
// Iris 在 shadow pass 把太阳相机矩阵绑定到 gl_ModelViewMatrix/
// gl_ProjectionMatrix（接收主相机相对坐标）。ftransform 在
// Iris 1.7.2 的 shadow pass 下顶点变换不可靠 → 大部分几何投影
// 出裁剪范围 → 阴影图大部分为空（clear 1.0）→ 无阴影。
// 显式矩阵乘法保证所有几何正确进入太阳相机裁剪空间
void main() {
	vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;
	gl_Position = gl_ProjectionMatrix * viewPos;
}
