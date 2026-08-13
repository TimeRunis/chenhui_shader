#version 450 compatibility
// 阴影 pass 顶点着色器（Derivative Main shadow.vert + ShadowDistortion 移植）：
// Iris 在 shadow pass 把太阳相机矩阵绑定到 gl_ModelViewMatrix/
// gl_ProjectionMatrix（接收主相机相对坐标）。显式矩阵乘法保证所有
// 几何正确进入太阳相机裁剪空间（ftransform 在 Iris 1.7.2 的 shadow
// pass 下不可靠）。
// 畸变（Derivative DistortShadowSpace）：xy 按四范数（1.165 系数 +
// SHADOW_MAP_BIAS=0.9 混合）向外畸变——shadow UV 中心区（视锥中心）
// 获得更高纹素密度（近处阴影更精细）；z×0.2 深度压缩——深度精度
// 提高 5 倍（近裁剪面附近）。采样端（shadowSample）用同一变换，
// 深度语义必须一致。

// 四范数（p4 距离）：(x⁴+y⁴)^(1/4)，1.165 缩放后畸变因子在 1.0（中心）
// 到 ~2.0（角落）之间按 SHADOW_MAP_BIAS 混合
float quarticLength(vec2 v) {
	float x2 = v.x * v.x;
	float y2 = v.y * v.y;
	return sqrt(sqrt(x2 * x2 + y2 * y2));
}

void main() {
	vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;
	vec3 clipPos = (gl_ProjectionMatrix * viewPos).xyz; // 正交投影：projMAD 等价（w 恒 1）
	float distortFactor = quarticLength(clipPos.xy * 1.165) * 0.9 + 0.1; // SHADOW_MAP_BIAS=0.9
	gl_Position = vec4(clipPos * vec3(vec2(1.0 / distortFactor), 0.2), 1.0);
}
