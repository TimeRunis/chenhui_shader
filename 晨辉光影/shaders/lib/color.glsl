// ================= 晨辉光影 · 色彩 =================
// 注意：本文件被 #include 使用，不写 #version

// ACES 拟合色调映射（Filmic，保留高光细节）
vec3 acesTonemap(vec3 x) {
	return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}
