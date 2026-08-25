package gpu_text

import gpu "../gpu"
import vk "vendor:vulkan"

text_renderer_create :: proc(ctx: ^gpu.Gpu_Context, allocator := context.allocator) -> Text_Renderer {
	return create_text_renderer(ctx, allocator)
}

text_renderer_create_with_desc :: proc(ctx: ^gpu.Gpu_Context, desc: Text_Renderer_Desc, allocator := context.allocator) -> Text_Renderer {
	return create_text_renderer_with_desc(ctx, desc, allocator)
}

text_renderer_destroy :: proc(ctx: ^gpu.Gpu_Context, renderer: ^Text_Renderer) {
	destroy_text_renderer(ctx, renderer)
}

text_measure_width :: proc(renderer: ^Text_Renderer, text: string, size: f32, font_id: u32) -> f32 {
	return measure_text_width(renderer, text, size, font_id)
}

text_measure_height :: proc(renderer: ^Text_Renderer, size: f32, font_id: u32) -> f32 {
	return measure_text_height(renderer, size, font_id)
}

draw_text_colored :: proc(
	ctx: ^gpu.Gpu_Context,
	renderer: ^Text_Renderer,
	cmd: vk.CommandBuffer,
	text: string,
	x, y, size: f32,
	color: [4]f32,
	scissor: vk.Rect2D,
	target_extent: vk.Extent2D = {},
) {
	draw_text(ctx, renderer, cmd, text, x, y, size, color, scissor, target_extent)
}

draw_text_colored_font :: proc(
	ctx: ^gpu.Gpu_Context,
	renderer: ^Text_Renderer,
	cmd: vk.CommandBuffer,
	text: string,
	x, y, size: f32,
	font_id: u32,
	color: [4]f32,
	scissor: vk.Rect2D,
	target_extent: vk.Extent2D = {},
) {
	draw_text_with_font(ctx, renderer, cmd, text, x, y, size, font_id, color, scissor, target_extent)
}
