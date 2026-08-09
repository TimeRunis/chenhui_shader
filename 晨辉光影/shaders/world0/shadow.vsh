#version 450 compatibility
// 阴影 pass 顶点着色器：ftransform() 应用 Iris 已绑定的阴影相机矩阵
// （shadowModelView/shadowProjection），输出深度写入 shadowtex0
void main() {
	gl_Position = ftransform();
}
