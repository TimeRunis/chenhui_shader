#version 450 compatibility
// 阴影 pass 片元着色器：深度自动写入 shadowtex0。
// 注意：此文件的存在 + shaders.properties 的 shadow.enabled=true 是
// Iris 启用阴影渲染 pass 的条件——此前缺失导致 shadowtex0 从未填充。
// 刻意保持最小实现：不采样任何 uniform（Iris 不一定向 shadow 程序提供
// texture/alphaTestRef，缺 uniform 会让整个 shadow program 编译失败
// → 阴影图空白 → 全场景"无阴影"）。代价：草/树叶会投实体阴影。
void main() {}
