#version 450 compatibility

// 丢弃原版日月（由 composite1 程序化绘制圆形日月）

layout(location = 0) out vec4 fragOut0;

void main() {
	discard;
}
