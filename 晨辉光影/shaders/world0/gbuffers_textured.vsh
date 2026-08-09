#version 450 compatibility

uniform vec3 cameraPosition;
uniform mat4 gbufferModelView;

out vec4 tint;
out vec2 texcoord;
out vec2 lightUV;
out vec3 minecraftPos;
out vec3 viewPos;
out vec3 normalV;

void main() {
	gl_Position = ftransform();
	tint = gl_Color;
	texcoord = gl_MultiTexCoord0.xy;
	lightUV = clamp(gl_MultiTexCoord1.xy * (1.0 / 240.0), 0.0, 1.0);
	minecraftPos = cameraPosition + gl_Vertex.xyz;
	viewPos = gl_Vertex.xyz;
	normalV = mat3(gbufferModelView) * gl_Normal;
}
