/*
Shader from Godot Shaders - the free shader library.
godotshaders.com/shader/pixelate

This shader is under CC0 license. Feel free to use, improve and 
change this shader according to your needs and consider sharing 
the modified result to godotshaders.com.
*/

shader_type canvas_item;

uniform int amount = 100;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

void fragment()
{
	vec2 grid_uv = round(UV * float(amount)) / float(amount);
	
	vec4 text = texture(screen_texture, grid_uv);
	
	COLOR = text;
}