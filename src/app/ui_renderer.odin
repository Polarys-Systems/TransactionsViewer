package app

import "core:fmt"
import "core:math"

import gpu "../gpu"
import gpu_text "../gpu_text"
import vk "vendor:vulkan"

UI_NO_TEXTURE :: ~u32(0)
UI_INSTANCE_BUFFER_SIZE :: u64(4 * 1024 * 1024)

UI_Instance :: struct {
	top_left:        [2]f32,
	bottom_right:    [2]f32,
	color_top:       [4]f32,
	color_bottom:    [4]f32,
	top_left_uv:     [2]f32,
	bottom_right_uv: [2]f32,
	radius:          f32,
	edge:            f32,
	clip_rect:       [4]f32,
	texture_index:   u32,
	sampler_index:   u32,
}

UI_Push_Constants :: struct {
	screen_width:  f32,
	screen_height: f32,
}

UI_Renderer :: struct {
	pipeline:         gpu.Gpu_Pipeline,
	instance_buffers: [dynamic]gpu.Gpu_Buffer,
	active_buffer:    ^gpu.Gpu_Buffer,
	instance_count:   int,
	instance_capacity: int,
	overflowed:       bool,
	sampler:          gpu.Gpu_Sampler_Handle,
	sampler_index:    u32,
}

ui_renderer_create :: proc(ctx: ^gpu.Gpu_Context, allocator := context.allocator) -> UI_Renderer {
	renderer: UI_Renderer
	binding := [1]vk.VertexInputBindingDescription{{
		binding = 0,
		stride = auto_cast size_of(UI_Instance),
		inputRate = .INSTANCE,
	}}
	attributes := [11]vk.VertexInputAttributeDescription{
		{binding = 0, location = 0, format = .R32G32_SFLOAT, offset = auto_cast offset_of(UI_Instance, top_left)},
		{binding = 0, location = 1, format = .R32G32_SFLOAT, offset = auto_cast offset_of(UI_Instance, bottom_right)},
		{binding = 0, location = 2, format = .R32G32B32A32_SFLOAT, offset = auto_cast offset_of(UI_Instance, color_top)},
		{binding = 0, location = 3, format = .R32G32B32A32_SFLOAT, offset = auto_cast offset_of(UI_Instance, color_bottom)},
		{binding = 0, location = 4, format = .R32G32_SFLOAT, offset = auto_cast offset_of(UI_Instance, top_left_uv)},
		{binding = 0, location = 5, format = .R32G32_SFLOAT, offset = auto_cast offset_of(UI_Instance, bottom_right_uv)},
		{binding = 0, location = 6, format = .R32_SFLOAT, offset = auto_cast offset_of(UI_Instance, radius)},
		{binding = 0, location = 7, format = .R32_SFLOAT, offset = auto_cast offset_of(UI_Instance, edge)},
		{binding = 0, location = 8, format = .R32G32B32A32_SFLOAT, offset = auto_cast offset_of(UI_Instance, clip_rect)},
		{binding = 0, location = 9, format = .R32_UINT, offset = auto_cast offset_of(UI_Instance, texture_index)},
		{binding = 0, location = 10, format = .R32_UINT, offset = auto_cast offset_of(UI_Instance, sampler_index)},
	}
	push_constant_range := [1]vk.PushConstantRange{{
		stageFlags = {.VERTEX},
		offset = 0,
		size = auto_cast size_of(UI_Push_Constants),
	}}
	desc := gpu.gpu_pipeline_desc_default_2d()
	desc.VertShaderCode = #load("../../shaders/ui_rect.vert.spv")
	desc.FragShaderCode = #load("../../shaders/ui_rect.frag.spv")
	desc.VertexBindings = binding[:]
	desc.VertexAttributes = attributes[:]
	desc.PushConstants = push_constant_range[:]
	renderer.pipeline = gpu.gpu_create_graphics_pipeline(ctx, desc)
	renderer.sampler = gpu.gpu_create_sampler(ctx, gpu.gpu_sampler_desc_default())
	sampler_index, sampler_ok := gpu.gpu_sampler_descriptor_index(ctx, renderer.sampler)
	if !sampler_ok {
		panic("[ERROR] Failed to create UI sampler")
	}
	renderer.sampler_index = sampler_index

	frame_count := int(gpu.gpu_frames_in_flight(ctx))
	renderer.instance_buffers = make([dynamic]gpu.Gpu_Buffer, frame_count, frame_count, allocator)
	for frame_slot in 0..<frame_count {
		renderer.instance_buffers[frame_slot] = gpu.gpu_create_buffer(
			ctx,
			UI_INSTANCE_BUFFER_SIZE,
			{.VERTEX_BUFFER},
			.Upload,
			"ui_instance_buffer",
		)
	}
	renderer.instance_capacity = int(UI_INSTANCE_BUFFER_SIZE / size_of(UI_Instance))
	return renderer
}

ui_renderer_destroy :: proc(ctx: ^gpu.Gpu_Context, renderer: ^UI_Renderer) {
	if renderer == nil {
		return
	}
	for &buffer in renderer.instance_buffers {
		gpu.gpu_destroy_buffer(ctx, &buffer)
	}
	delete(renderer.instance_buffers)
	gpu.gpu_destroy_sampler(ctx, renderer.sampler)
	gpu.gpu_destroy_pipeline(ctx, &renderer.pipeline)
	renderer^ = {}
}

ui_renderer_begin :: proc(ctx: ^gpu.Gpu_Context, renderer: ^UI_Renderer) {
	if renderer == nil {
		return
	}
	frame_slot := int(gpu.gpu_current_frame_slot(ctx))
	renderer.active_buffer = &renderer.instance_buffers[frame_slot]
	renderer.instance_count = 0
	renderer.overflowed = false
}

ui_renderer_push_instance :: #force_inline proc(renderer: ^UI_Renderer, instance: UI_Instance) -> bool {
	if renderer == nil || renderer.active_buffer == nil || renderer.active_buffer.cpu == nil {
		return false
	}
	if renderer.instance_count >= renderer.instance_capacity {
		renderer.overflowed = true
		return false
	}
	instances := ([^]UI_Instance)(renderer.active_buffer.cpu)
	instances[renderer.instance_count] = instance
	renderer.instance_count += 1
	return true
}

ui_renderer_push_rect :: proc(
	renderer: ^UI_Renderer,
	top_left, bottom_right: [2]f32,
	color_top, color_bottom: [4]f32,
	radius, edge: f32,
	clip_rect: [4]f32,
) {
	if renderer == nil || bottom_right.x <= top_left.x || bottom_right.y <= top_left.y {
		return
	}
	_ = ui_renderer_push_instance(renderer, UI_Instance{
		top_left = top_left,
		bottom_right = bottom_right,
		color_top = color_top,
		color_bottom = color_bottom,
		radius = radius,
		edge = edge,
		clip_rect = clip_rect,
		texture_index = UI_NO_TEXTURE,
	})
}

ui_renderer_push_text :: proc(
	renderer: ^UI_Renderer,
	font: ^gpu_text.Text_Font,
	text: string,
	x, y: f32,
	color: [4]f32,
	clip_rect: [4]f32,
) {
	if renderer == nil || font == nil || font.Renderer == nil || len(text) == 0 {
		return
	}
	cursor_x := x
	cursor_y := y + font.Metrics.ascent
	for codepoint in text {
		switch codepoint {
		case '\r':
			continue
		case '\n':
			cursor_x = x
			cursor_y += font.Metrics.line_height
			continue
		}
		glyph, ok := gpu_text.text_font_get_glyph(font, codepoint)
		if !ok {
			continue
		}
		if glyph.state == .Resident {
			px := math.floor(cursor_x + glyph.xoff + 0.5)
			py := math.floor(cursor_y + glyph.yoff + 0.5)
			_ = ui_renderer_push_instance(renderer, UI_Instance{
				top_left = {px, py},
				bottom_right = {px + glyph.xoff2-glyph.xoff, py + glyph.yoff2-glyph.yoff},
				color_top = color,
				color_bottom = color,
				top_left_uv = {glyph.u0, glyph.v0},
				bottom_right_uv = {glyph.u1, glyph.v1},
				clip_rect = clip_rect,
				texture_index = glyph.texture_index,
				sampler_index = renderer.sampler_index,
			})
		}
		cursor_x += glyph.advance_x
		cursor_y += glyph.advance_y
	}
}

ui_renderer_push_icon :: proc(
	renderer: ^UI_Renderer,
	font: ^gpu_text.Text_Font,
	codepoint: rune,
	x, y, width, height: f32,
	color: [4]f32,
	clip_rect: [4]f32,
) {
	if renderer == nil || font == nil || codepoint == 0 || width <= 0 || height <= 0 {
		return
	}
	glyph, ok := gpu_text.text_font_get_glyph(font, codepoint)
	if !ok || glyph.state != .Resident {
		return
	}
	glyph_width := glyph.xoff2 - glyph.xoff
	glyph_height := glyph.yoff2 - glyph.yoff
	px := math.floor(x + (width-glyph_width)*0.5 + 0.5)
	py := math.floor(y + (height-glyph_height)*0.5 + 0.5)
	_ = ui_renderer_push_instance(renderer, UI_Instance{
		top_left = {px, py},
		bottom_right = {px + glyph_width, py + glyph_height},
		color_top = color,
		color_bottom = color,
		top_left_uv = {glyph.u0, glyph.v0},
		bottom_right_uv = {glyph.u1, glyph.v1},
		clip_rect = clip_rect,
		texture_index = glyph.texture_index,
		sampler_index = renderer.sampler_index,
	})
}

ui_renderer_draw :: proc(
	ctx: ^gpu.Gpu_Context,
	renderer: ^UI_Renderer,
	cmd: vk.CommandBuffer,
	extent: vk.Extent2D,
) {
	if renderer == nil || renderer.instance_count == 0 || renderer.active_buffer == nil {
		return
	}
	if renderer.overflowed {
		fmt.println("[WARN] UI instance buffer full, UI was truncated")
	}
	instance_buffer := renderer.active_buffer
	buffer_size := u64(renderer.instance_count * size_of(UI_Instance))
	gpu.gpu_flush_buffer(instance_buffer, 0, buffer_size)

	viewport := vk.Viewport{
		x = 0,
		y = 0,
		width = f32(extent.width),
		height = f32(extent.height),
		minDepth = 0,
		maxDepth = 1,
	}
	full_scissor := vk.Rect2D{offset = {0, 0}, extent = extent}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)
	vk.CmdSetScissor(cmd, 0, 1, &full_scissor)
	gpu.gpu_bind_pipeline(ctx, cmd, &renderer.pipeline)
	push_constants := UI_Push_Constants{
		screen_width = f32(extent.width),
		screen_height = f32(extent.height),
	}
	_ = gpu.gpu_push_constants(
		ctx,
		cmd,
		&renderer.pipeline,
		{.VERTEX},
		&push_constants,
		auto_cast size_of(UI_Push_Constants),
	)
	offset: vk.DeviceSize
	vk.CmdBindVertexBuffers(cmd, 0, 1, &instance_buffer.buffer, &offset)
	vk.CmdDraw(cmd, 6, auto_cast renderer.instance_count, 0, 0)
}
