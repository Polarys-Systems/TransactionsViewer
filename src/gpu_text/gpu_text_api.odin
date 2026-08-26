package gpu_text

import gpu "../gpu"

text_renderer_create :: proc(ctx: ^gpu.Gpu_Context, allocator := context.allocator) -> Text_Renderer {
	return create_text_renderer(ctx, allocator)
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
