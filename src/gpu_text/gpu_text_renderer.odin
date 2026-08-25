package gpu_text

/*
Text shaping + atlas-backed draw submission.

Example:
	desc := text_renderer_desc_default()
	desc.font_path = "assets/fonts/ElmsSans.ttf"
	text := text_renderer_create_with_desc(ctx, desc)
	defer text_renderer_destroy(ctx, &text)
	_ = text_renderer_prepare_default(&text, "Hello", 24)
	text_renderer_upload(ctx, &text)
	draw_text(ctx, &text, cmd, "Hello", 50, 50, 24)
*/

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:os"

import fontlib "../font"
import gpu "../gpu"
import vk "vendor:vulkan"
import kbts "vendor:kb_text_shape"

Text_Vertex :: struct {
	pos: [2]f32,
	uv:  [2]f32,
}

Text_Push_Constants :: struct {
	color:         [4]f32,
	texture_index: u32,
	sampler_index: u32,
}

Text_Batch :: struct {
	page_index: int,
	vertices:   [dynamic]Text_Vertex,
}

Text_Font_Record :: struct {
	atlas_font_id: u32,
	shape_font:    ^kbts.font,
	path:          string,
}

Text_Renderer :: struct {
	ctx:                   ^gpu.Gpu_Context,
	Pipeline:              gpu.Gpu_Pipeline,
	AtlasManager:          ^Atlas_Manager,
	Fonts:                 [dynamic]Text_Font_Record,
	DefaultFont:           u32,
	IconFont:              u32,
	FallbackFonts:         [dynamic]u32,
	ShapeContext:          ^kbts.shape_context,
	ShapeFontByAtlasFontID: map[u32]^kbts.font,
	AtlasFontByShapeFont:   map[uintptr]u32,
	ShapeAllocator:        ^runtime.Allocator,
	VertexBuffers:         [dynamic]gpu.Gpu_Buffer,
	CurrentVertexOffsets:  [dynamic]int,
	FrameEpochs:           [dynamic]u64,
	Sampler:               gpu.Gpu_Sampler_Handle,
	SamplerIndex:          u32,
	VertShaderPath:        string,
	FragShaderPath:        string,
}

Text_Renderer_Desc :: struct {
	font_path:         string,
	vert_shader_path:  string,
	frag_shader_path:  string,
	vertex_buffer_size: u64,
}

text_renderer_desc_default :: proc() -> Text_Renderer_Desc {
	return Text_Renderer_Desc{
		font_path          = "",
		vert_shader_path   = "shaders/text.vert.spv",
		frag_shader_path   = "shaders/text.frag.spv",
		// 4 MiB ≈ 43k glyphs/frame. The whole text buffer is filled per frame
		// (offset resets each frame), so this must cover the densest screen
		// (full console table + detail drawer + profiler overlay) at once.
		vertex_buffer_size = 4 * 1024 * 1024,
	}
}

shape_font_key :: #force_inline proc(font: ^kbts.font) -> uintptr {
	return uintptr(transmute(rawptr)font)
}

text_font_id_valid :: proc(renderer: ^Text_Renderer, font_id: u32) -> bool {
	if renderer == nil || renderer.AtlasManager == nil {
		return false
	}
	return int(font_id) >= 0 && int(font_id) < len(renderer.AtlasManager.fonts)
}

text_renderer_resolve_font_id :: proc(renderer: ^Text_Renderer, requested: u32) -> u32 {
	if text_font_id_valid(renderer, requested) {
		return requested
	}
	if text_font_id_valid(renderer, renderer.DefaultFont) {
		return renderer.DefaultFont
	}
	if renderer != nil && renderer.AtlasManager != nil && len(renderer.AtlasManager.fonts) > 0 {
		return renderer.AtlasManager.fonts[0].id
	}
	return 0
}

text_renderer_set_default_font :: proc(renderer: ^Text_Renderer, font_id: u32) -> bool {
	if !text_font_id_valid(renderer, font_id) {
		return false
	}
	renderer.DefaultFont = font_id
	return true
}

text_renderer_set_icon_font :: proc(renderer: ^Text_Renderer, font_id: u32) -> bool {
	if !text_font_id_valid(renderer, font_id) {
		return false
	}
	renderer.IconFont = font_id
	return true
}

text_renderer_add_fallback_font :: proc(renderer: ^Text_Renderer, font_id: u32) -> bool {
	if !text_font_id_valid(renderer, font_id) {
		return false
	}
	for existing in renderer.FallbackFonts {
		if existing == font_id {
			return true
		}
	}
	append(&renderer.FallbackFonts, font_id)
	return true
}

text_renderer_set_fallback_fonts :: proc(renderer: ^Text_Renderer, font_ids: []u32) {
	if renderer == nil {
		return
	}
	clear(&renderer.FallbackFonts)
	for font_id in font_ids {
		_ = text_renderer_add_fallback_font(renderer, font_id)
	}
}

text_renderer_shape_font_for_font_id :: proc(renderer: ^Text_Renderer, font_id: u32) -> (^kbts.font, bool) {
	if renderer == nil {
		return nil, false
	}
	shape_font, ok := renderer.ShapeFontByAtlasFontID[font_id]
	if !ok || shape_font == nil {
		return nil, false
	}
	return shape_font, true
}

text_renderer_register_font_data :: proc(
	renderer: ^Text_Renderer,
	font_data: []byte,
	font_path: string,
) -> (font_id: u32, ok: bool) {
	if renderer == nil || renderer.AtlasManager == nil || renderer.ShapeContext == nil || len(font_data) == 0 {
		return 0, false
	}

	atlas_font_id, atlas_ok := atlas_manager_register_font(renderer.AtlasManager, font_data)
	font_id = atlas_font_id
	if !atlas_ok || !text_font_id_valid(renderer, font_id) {
		return 0, false
	}

	shape_font := kbts.ShapePushFontFromMemory(
		renderer.ShapeContext,
		renderer.AtlasManager.fonts[font_id].face.data,
		0,
	)
	if shape_font == nil {
		_ = atlas_manager_unregister_last_font(renderer.AtlasManager, font_id)
		return 0, false
	}

	renderer.ShapeFontByAtlasFontID[font_id] = shape_font
	renderer.AtlasFontByShapeFont[shape_font_key(shape_font)] = font_id
	append(&renderer.Fonts, Text_Font_Record{
		atlas_font_id = font_id,
		shape_font    = shape_font,
		path          = font_path,
	})
	return font_id, true
}

text_renderer_register_font :: proc(
	renderer: ^Text_Renderer,
	font_path: string,
	allocator := context.allocator,
) -> (font_id: u32, ok: bool) {
	if renderer == nil || renderer.AtlasManager == nil || renderer.ShapeContext == nil {
		return 0, false
	}

	font_data, err := os.read_entire_file(font_path, allocator)
	if err != nil {
		fmt.printf("[WARN] text_renderer_register_font: failed to load %q\n", font_path)
		return 0, false
	}
	defer delete(font_data, allocator)

	font_id, ok = text_renderer_register_font_data(renderer, font_data, font_path)
	if !ok {
		fmt.printf("[WARN] text_renderer_register_font: registration failed for %q\n", font_path)
		return 0, false
	}
	return font_id, true
}

// Prepare rasterizes and uploads missing glyphs. Call it before beginning a
// dynamic-rendering pass; draw procedures never submit transfer work.
text_renderer_prepare :: proc(
	renderer: ^Text_Renderer,
	text: string,
	size: f32,
	font_id: u32,
) -> bool {
	if renderer == nil || renderer.AtlasManager == nil || size <= 0 || len(text) == 0 {
		return false
	}
	resolved := text_renderer_resolve_font_id(renderer, font_id)
	if !text_font_id_valid(renderer, resolved) {
		return false
	}
	_ = build_text_quads(renderer, text, 0, 0, size, resolved)
	return true
}

text_renderer_prepare_default :: proc(
	renderer: ^Text_Renderer,
	text: string,
	size: f32,
) -> bool {
	if renderer == nil do return false
	return text_renderer_prepare(renderer, text, size, renderer.DefaultFont)
}

text_renderer_prepare_icon :: proc(
	renderer: ^Text_Renderer,
	codepoint: rune,
	size: f32,
) -> bool {
	if renderer == nil || renderer.AtlasManager == nil || codepoint == 0 || size <= 0 {
		return false
	}
	font_id := text_renderer_resolve_font_id(renderer, renderer.IconFont)
	if !text_font_id_valid(renderer, font_id) {
		return false
	}
	glyph_index, ok := fontlib.glyph_index(&renderer.AtlasManager.fonts[font_id].face, codepoint)
	if !ok {
		return false
	}
	_, ok = atlas_manager_get_glyph(renderer.AtlasManager, font_id, size, u16(glyph_index))
	return ok
}

text_renderer_upload :: proc(ctx: ^gpu.Gpu_Context, renderer: ^Text_Renderer) {
	if renderer == nil || renderer.AtlasManager == nil || !renderer.AtlasManager.pending_uploads {
		return
	}
	gpu.gpu_upload_flush(ctx)
	renderer.AtlasManager.pending_uploads = false
}

create_text_renderer_with_desc :: proc(ctx: ^gpu.Gpu_Context, desc: Text_Renderer_Desc, allocator := context.allocator) -> Text_Renderer {
	renderer: Text_Renderer
	renderer.ctx = ctx
	renderer.VertShaderPath = desc.vert_shader_path
	renderer.FragShaderPath = desc.frag_shader_path

	renderer.ShapeAllocator = new(runtime.Allocator, allocator)
	renderer.ShapeAllocator^ = allocator
	alloc_fn, alloc_data := kbts.AllocatorFromOdinAllocator(renderer.ShapeAllocator)
	renderer.ShapeContext = kbts.CreateShapeContext(alloc_fn, alloc_data)
	renderer.Fonts = make([dynamic]Text_Font_Record, 0, 8, allocator)
	renderer.FallbackFonts = make([dynamic]u32, 0, 8, allocator)
	renderer.ShapeFontByAtlasFontID = make(map[u32]^kbts.font, 8, allocator)
	renderer.AtlasFontByShapeFont = make(map[uintptr]u32, 8, allocator)

	init_text_pipeline(ctx, &renderer)

	renderer.Sampler = gpu.gpu_create_sampler(ctx, gpu.gpu_sampler_desc_default())
	sampler_index, sampler_ok := gpu.gpu_sampler_descriptor_index(ctx, renderer.Sampler)
	if !sampler_ok {
		panic("[ERROR] Failed to create text sampler")
	}
	renderer.SamplerIndex = sampler_index

	renderer.AtlasManager = create_atlas_manager(ctx, allocator)
	if len(desc.font_path) > 0 {
		font_data, err := os.read_entire_file(desc.font_path, allocator)
		if err != nil {
			panic("[ERROR] Failed to load font file")
		}
		defer delete(font_data, allocator)

		default_font_id, default_ok := text_renderer_register_font_data(&renderer, font_data, desc.font_path)
		if !default_ok {
			panic("[ERROR] Failed to register default font")
		}
		renderer.DefaultFont = default_font_id
		renderer.IconFont = default_font_id
	}

	buffer_size := desc.vertex_buffer_size
	if buffer_size == 0 {
		buffer_size = 4 * 1024 * 1024
	}
	frame_count := int(gpu.gpu_frames_in_flight(ctx))
	assert(frame_count > 0)
	renderer.VertexBuffers = make([dynamic]gpu.Gpu_Buffer, frame_count, frame_count, allocator)
	renderer.CurrentVertexOffsets = make([dynamic]int, frame_count, frame_count, allocator)
	renderer.FrameEpochs = make([dynamic]u64, frame_count, frame_count, allocator)
	for frame_slot in 0..<frame_count {
		renderer.FrameEpochs[frame_slot] = ~u64(0)
		renderer.VertexBuffers[frame_slot] = gpu.gpu_create_buffer(
			ctx,
			buffer_size,
			{.VERTEX_BUFFER},
			.Upload,
			"text_vertex_buffer",
		)
	}

	return renderer
}

create_text_renderer :: proc(ctx: ^gpu.Gpu_Context, allocator := context.allocator) -> Text_Renderer {
	return create_text_renderer_with_desc(ctx, text_renderer_desc_default(), allocator)
}

destroy_text_renderer :: proc(ctx: ^gpu.Gpu_Context, renderer: ^Text_Renderer) {
	if renderer == nil {
		return
	}

	gpu.gpu_destroy_pipeline(ctx, &renderer.Pipeline)
	for &vertex_buffer in renderer.VertexBuffers {
		gpu.gpu_destroy_buffer(ctx, &vertex_buffer)
	}
	delete(renderer.VertexBuffers)
	delete(renderer.CurrentVertexOffsets)
	delete(renderer.FrameEpochs)

	if renderer.ShapeContext != nil {
		for i := 0; i < len(renderer.Fonts); i += 1 {
			_ = kbts.ShapePopFont(renderer.ShapeContext)
		}
		kbts.DestroyShapeContext(renderer.ShapeContext)
		renderer.ShapeContext = nil
	}
	if renderer.ShapeAllocator != nil {
		shape_allocator := renderer.ShapeAllocator^
		free(renderer.ShapeAllocator, shape_allocator)
		renderer.ShapeAllocator = nil
	}

	destroy_atlas_manager(renderer.AtlasManager)
	delete(renderer.ShapeFontByAtlasFontID)
	delete(renderer.AtlasFontByShapeFont)
	delete(renderer.FallbackFonts)
	delete(renderer.Fonts)
	gpu.gpu_destroy_sampler(ctx, renderer.Sampler)
	renderer^ = {}
}

init_text_pipeline :: proc(ctx: ^gpu.Gpu_Context, renderer: ^Text_Renderer) {
	binding := [1]vk.VertexInputBindingDescription {
		{
			binding   = 0,
			stride   = auto_cast size_of(Text_Vertex),
			inputRate = .VERTEX,
		},
	}
	attributes := [2]vk.VertexInputAttributeDescription {
		{
			binding  = 0,
			location = 0,
			format   = .R32G32_SFLOAT,
			offset   = auto_cast offset_of(Text_Vertex, pos),
		},
		{
			binding  = 0,
			location = 1,
			format   = .R32G32_SFLOAT,
			offset   = auto_cast offset_of(Text_Vertex, uv),
		},
	}

	push_constant_range := [1]vk.PushConstantRange {
		{
			stageFlags = {.FRAGMENT},
			offset     = 0,
			size       = auto_cast size_of(Text_Push_Constants),
		},
	}

	desc := gpu.gpu_pipeline_desc_default_2d()
	desc.VertShaderPath = renderer.VertShaderPath
	desc.FragShaderPath = renderer.FragShaderPath
	desc.VertexBindings = binding[:]
	desc.VertexAttributes = attributes[:]
	desc.PushConstants = push_constant_range[:]

	renderer.Pipeline = gpu.gpu_create_graphics_pipeline(ctx, desc)
}

text_renderer_current_vertex_slot :: proc(ctx: ^gpu.Gpu_Context, renderer: ^Text_Renderer) -> int {
	frame_slot := int(gpu.gpu_current_frame_slot(ctx))
	assert(frame_slot < len(renderer.VertexBuffers))
	assert(frame_slot < len(renderer.CurrentVertexOffsets))
	assert(frame_slot < len(renderer.FrameEpochs))

	frame_epoch := gpu.gpu_frame_index(ctx)
	if renderer.FrameEpochs[frame_slot] != frame_epoch {
		renderer.FrameEpochs[frame_slot] = frame_epoch
		renderer.CurrentVertexOffsets[frame_slot] = 0
	}
	return frame_slot
}

draw_text :: proc(
	ctx: ^gpu.Gpu_Context,
	renderer: ^Text_Renderer,
	cmd: vk.CommandBuffer,
	text: string,
	x, y, size: f32,
	color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
	scissor_override: vk.Rect2D = {},
	target_extent: vk.Extent2D = {},
) {
	draw_text_with_font(
		ctx,
		renderer,
		cmd,
		text,
		x,
		y,
		size,
		renderer.DefaultFont,
		color,
		scissor_override,
		target_extent,
	)
}

draw_text_with_font :: proc(
	ctx: ^gpu.Gpu_Context,
	renderer: ^Text_Renderer,
	cmd: vk.CommandBuffer,
	text: string,
	x, y, size: f32,
	font_id: u32,
	color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
	scissor_override: vk.Rect2D = {},
	target_extent: vk.Extent2D = {},
) {
	if size <= 0.0 || len(text) == 0 {
		return
	}

	resolved_font_id := text_renderer_resolve_font_id(renderer, font_id)
	batches := build_text_quads(renderer, text, x, y, size, resolved_font_id)
	if len(batches) == 0 {
		fmt.println("[WARN] draw_text: no vertices generated")
		return
	}

	if renderer.AtlasManager.pending_uploads {
		fmt.println("[WARN] gpu_text: text was not prepared before rendering")
		return
	}

	total_verts := 0
	for batch in batches {
		total_verts += len(batch.vertices)
	}
	total_buf_size := total_verts * size_of(Text_Vertex)

	frame_slot := text_renderer_current_vertex_slot(ctx, renderer)
	vertex_buffer := &renderer.VertexBuffers[frame_slot]
	current_vertex_offset := renderer.CurrentVertexOffsets[frame_slot]
	if current_vertex_offset + total_buf_size > int(vertex_buffer.size) {
		fmt.println("[WARN] draw_text: vertex buffer overflow, skipping text")
		return
	}

	extent := target_extent
	if extent.width == 0 || extent.height == 0 {
		extent = gpu.gpu_swapchain_extent(ctx)
	}
	w := f32(extent.width)
	h := f32(extent.height)

	// Convert to NDC and copy all vertices into the GPU buffer at the current frame offset
	base_offset := current_vertex_offset
	write_offset := base_offset
	for &batch in batches {
		for i in 0 ..< len(batch.vertices) {
			batch.vertices[i].pos.x = (2.0 * batch.vertices[i].pos.x / w) - 1.0
			batch.vertices[i].pos.y = (2.0 * batch.vertices[i].pos.y / h) - 1.0
		}
		buf_size := len(batch.vertices) * size_of(Text_Vertex)
		libc.memcpy(
			rawptr(uintptr(vertex_buffer.cpu) + uintptr(write_offset)),
			raw_data(batch.vertices),
			auto_cast buf_size,
		)
		write_offset += buf_size
	}
	if write_offset > base_offset {
		gpu.gpu_flush_buffer(vertex_buffer, u64(base_offset), u64(write_offset-base_offset))
	}

	vk.CmdBindPipeline(cmd, .GRAPHICS, renderer.Pipeline.Pipeline)

	viewport := vk.Viewport {
		x = 0, y = 0,
		width = w, height = h,
		minDepth = 0.0, maxDepth = 1.0,
	}
	scissor := vk.Rect2D{offset = {0, 0}, extent = extent}
	if scissor_override.extent.width > 0 && scissor_override.extent.height > 0 {
		scissor = scissor_override
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)
	vk.CmdSetScissor(cmd, 0, 1, &scissor)

	bindless_set := gpu.gpu_bindless_set(ctx)
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, renderer.Pipeline.Layout, 0, 1, &bindless_set, 0, nil)

	// Draw each batch with its atlas page index.
	draw_offset := base_offset
	for batch in batches {
		page := &renderer.AtlasManager.pages[batch.page_index]
		push_constants := Text_Push_Constants{
			color         = color,
			texture_index = page.texture_index,
			sampler_index = renderer.SamplerIndex,
		}
		vk.CmdPushConstants(cmd, renderer.Pipeline.Layout, {.FRAGMENT}, 0, auto_cast size_of(Text_Push_Constants), &push_constants)

		offset: vk.DeviceSize = auto_cast draw_offset
		vk.CmdBindVertexBuffers(cmd, 0, 1, &vertex_buffer.buffer, &offset)
		vk.CmdDraw(cmd, auto_cast len(batch.vertices), 1, 0, 0)

		draw_offset += len(batch.vertices) * size_of(Text_Vertex)
	}

	renderer.CurrentVertexOffsets[frame_slot] = draw_offset
}

text_baseline_offset :: proc(renderer: ^Text_Renderer, size: f32) -> f32 {
	return text_baseline_offset_for_font(renderer, renderer.DefaultFont, size)
}

text_baseline_offset_for_font :: proc(renderer: ^Text_Renderer, font_id: u32, size: f32) -> f32 {
	if renderer == nil || renderer.AtlasManager == nil {
		return 0.0
	}
	if size <= 0.0 {
		return 0.0
	}
	resolved_font_id := text_renderer_resolve_font_id(renderer, font_id)
	if !text_font_id_valid(renderer, resolved_font_id) {
		return 0.0
	}

	metrics := atlas_manager_get_line_metrics(renderer.AtlasManager, resolved_font_id, size)
	return metrics.ascent
}

text_renderer_can_draw_icon_codepoint :: proc(renderer: ^Text_Renderer, codepoint: rune) -> bool {
	if renderer == nil || renderer.AtlasManager == nil || codepoint == 0 {
		return false
	}
	icon_font_id := text_renderer_resolve_font_id(renderer, renderer.IconFont)
	if !text_font_id_valid(renderer, icon_font_id) {
		return false
	}
	_, ok := fontlib.glyph_index(&renderer.AtlasManager.fonts[icon_font_id].face, codepoint)
	return ok
}

text_renderer_font_id_from_run :: proc(renderer: ^Text_Renderer, run_font: ^kbts.font, preferred_font_id: u32) -> u32 {
	if run_font != nil {
		if font_id, ok := renderer.AtlasFontByShapeFont[shape_font_key(run_font)]; ok && text_font_id_valid(renderer, font_id) {
			return font_id
		}
	}
	return text_renderer_resolve_font_id(renderer, preferred_font_id)
}

text_batch_append_quad :: proc(
	batches: ^[dynamic]Text_Batch,
	page_index: int,
	x0, y0, x1, y1, u0, v0, u1, v1: f32,
) {
	if batches == nil || page_index < 0 {
		return
	}
	if len(batches^) == 0 || batches^[len(batches^) - 1].page_index != page_index {
		append(batches, Text_Batch{
			page_index = page_index,
			vertices   = make([dynamic]Text_Vertex, 0, 64, context.temp_allocator),
		})
	}

	batch := &batches^[len(batches^) - 1]
	append(&batch.vertices, Text_Vertex{{x0, y0}, {u0, v0}})
	append(&batch.vertices, Text_Vertex{{x1, y1}, {u1, v1}})
	append(&batch.vertices, Text_Vertex{{x0, y1}, {u0, v1}})
	append(&batch.vertices, Text_Vertex{{x0, y0}, {u0, v0}})
	append(&batch.vertices, Text_Vertex{{x1, y0}, {u1, v0}})
	append(&batch.vertices, Text_Vertex{{x1, y1}, {u1, v1}})
}

text_try_find_glyph_index_in_font :: proc(
	renderer: ^Text_Renderer,
	font_id: u32,
	r: rune,
) -> (glyph_idx: i32, ok: bool) {
	if !text_font_id_valid(renderer, font_id) {
		return 0, false
	}
	return fontlib.glyph_index(&renderer.AtlasManager.fonts[font_id].face, r)
}

text_resolve_glyph_for_codepoint :: proc(
	renderer: ^Text_Renderer,
	preferred_font_id: u32,
	r: rune,
) -> (font_id: u32, glyph_idx: i32, ok: bool) {
	resolved_preferred := text_renderer_resolve_font_id(renderer, preferred_font_id)

	if glyph_idx, found := text_try_find_glyph_index_in_font(renderer, resolved_preferred, r); found {
		return resolved_preferred, glyph_idx, true
	}

	for fallback_font_id in renderer.FallbackFonts {
		if fallback_font_id == resolved_preferred {
			continue
		}
		if glyph_idx, found := text_try_find_glyph_index_in_font(renderer, fallback_font_id, r); found {
			return fallback_font_id, glyph_idx, true
		}
	}

	if r != '?' {
		if glyph_idx, found := text_try_find_glyph_index_in_font(renderer, resolved_preferred, '?'); found {
			return resolved_preferred, glyph_idx, true
		}
		for fallback_font_id in renderer.FallbackFonts {
			if fallback_font_id == resolved_preferred {
				continue
			}
			if glyph_idx, found := text_try_find_glyph_index_in_font(renderer, fallback_font_id, '?'); found {
				return fallback_font_id, glyph_idx, true
			}
		}
	}

	return 0, 0, false
}

text_renderer_push_shape_fonts :: proc(renderer: ^Text_Renderer, preferred_font_id: u32) -> int {
	if renderer == nil || renderer.ShapeContext == nil {
		return 0
	}

	pushed := 0
	if shape_font, ok := text_renderer_shape_font_for_font_id(renderer, preferred_font_id); ok {
		_ = kbts.ShapePushFont(renderer.ShapeContext, shape_font)
		pushed += 1
	}
	for fallback_font_id in renderer.FallbackFonts {
		if fallback_font_id == preferred_font_id {
			continue
		}
		shape_font, ok := text_renderer_shape_font_for_font_id(renderer, fallback_font_id)
		if !ok {
			continue
		}
		_ = kbts.ShapePushFont(renderer.ShapeContext, shape_font)
		pushed += 1
	}

	return pushed
}

text_renderer_pop_shape_fonts :: proc(renderer: ^Text_Renderer, count: int) {
	if renderer == nil || renderer.ShapeContext == nil {
		return
	}
	for i := 0; i < count; i += 1 {
		_ = kbts.ShapePopFont(renderer.ShapeContext)
	}
}

measure_text_width_unshaped :: proc(
	renderer: ^Text_Renderer,
	text: string,
	size: f32,
	font_id: u32,
) -> f32 {
	line_width, max_width: f32
	raster_size := atlas_size_from_quantized_64(atlas_quantize_size_64(size))

	for r in text {
		if r == '\r' {
			continue
		}
		if r == '\n' {
			max_width = max(max_width, line_width)
			line_width = 0
			continue
		}

		glyph_font_id, glyph_idx, ok := text_resolve_glyph_for_codepoint(renderer, font_id, r)
		if !ok {
			continue
		}
		line_width += fontlib.glyph_advance(
			&renderer.AtlasManager.fonts[glyph_font_id].face,
			glyph_idx,
			raster_size,
		)
	}

	return max(max_width, line_width)
}

measure_text_width :: proc(renderer: ^Text_Renderer, text: string, size: f32, font_id: u32) -> f32 {
	if renderer == nil || renderer.AtlasManager == nil || len(text) == 0 || size <= 0 {
		return 0
	}

	resolved_font_id := text_renderer_resolve_font_id(renderer, font_id)
	if !text_font_id_valid(renderer, resolved_font_id) {
		return 0
	}

	if text_is_simple_latin(text) || renderer.ShapeContext == nil {
		return measure_text_width_unshaped(renderer, text, size, resolved_font_id)
	}

	pushed_shape_fonts := text_renderer_push_shape_fonts(renderer, resolved_font_id)
	if pushed_shape_fonts == 0 {
		return measure_text_width_unshaped(renderer, text, size, resolved_font_id)
	}
	defer text_renderer_pop_shape_fonts(renderer, pushed_shape_fonts)

	kbts.ShapeBegin(renderer.ShapeContext, .KBTS_DIRECTION_LTR, .ENGLISH)
	kbts.ShapeUtf8(renderer.ShapeContext, text, .CODEPOINT_INDEX)
	kbts.ShapeEnd(renderer.ShapeContext)

	width: f32
	for {
		run, ok := kbts.ShapeRun(renderer.ShapeContext)
		if !ok {
			break
		}
		run_font_id := text_renderer_font_id_from_run(renderer, run.Font, resolved_font_id)
		scale := fontlib.shape_scale(&renderer.AtlasManager.fonts[run_font_id].face, size)
		for {
			glyph, glyph_ok := kbts.GlyphIteratorNext(&run.Glyphs)
			if !glyph_ok {
				break
			}
			width += f32(glyph.AdvanceX) * scale
		}
	}
	return width
}

measure_text_height :: proc(renderer: ^Text_Renderer, size: f32, font_id: u32) -> f32 {
	if renderer == nil || renderer.AtlasManager == nil || size <= 0 {
		return 0
	}
	resolved_font_id := text_renderer_resolve_font_id(renderer, font_id)
	if !text_font_id_valid(renderer, resolved_font_id) {
		return 0
	}
	return atlas_manager_get_line_metrics(renderer.AtlasManager, resolved_font_id, size).line_height
}

text_is_private_use_symbol :: proc(r: rune) -> bool {
	return (r >= rune(0xE000) && r <= rune(0xF8FF)) ||
	       (r >= rune(0xF0000) && r <= rune(0x10FFFD))
}

text_is_simple_latin :: proc(text: string) -> bool {
	for r in text {
		if text_is_private_use_symbol(r) {
			continue
		}
		if r <= rune(0x024F) ||
		   (r >= rune(0x0300) && r <= rune(0x036F)) ||
		   (r >= rune(0x1E00) && r <= rune(0x1EFF)) {
			continue
		}
		return false
	}
	return true
}

build_text_quads_unshaped :: proc(
	renderer: ^Text_Renderer,
	text: string,
	x, y, size: f32,
	font_id: u32,
) -> []Text_Batch {
	if renderer == nil || renderer.AtlasManager == nil || len(text) == 0 {
		return nil
	}
	if !text_font_id_valid(renderer, font_id) {
		return nil
	}

	batches := make([dynamic]Text_Batch, 0, 16, context.temp_allocator)

	metrics := atlas_manager_get_line_metrics(renderer.AtlasManager, font_id, size)
	line_advance := metrics.line_height
	if line_advance <= 0.0 {
		line_advance = max(size, 1.0)
	}

	cursor_x := x
	cursor_y := y
	for r in text {
		if r == '\r' {
			continue
		}
		if r == '\n' {
			cursor_x = x
			cursor_y += line_advance
			continue
		}

		glyph_font_id, glyph_idx, glyph_ok := text_resolve_glyph_for_codepoint(renderer, font_id, r)
		if !glyph_ok {
			continue
		}
		entry, found := atlas_manager_get_glyph(renderer.AtlasManager, glyph_font_id, size, u16(glyph_idx))
		if found && entry.page_index >= 0 && (entry.x1-entry.x0) > 0 {
			px := math.floor(cursor_x + entry.xoff + 0.5)
			py := math.floor(cursor_y + entry.yoff + 0.5)

			x0 := px
			y0 := py
			x1 := px + (entry.xoff2 - entry.xoff)
			y1 := py + (entry.yoff2 - entry.yoff)

			text_batch_append_quad(
				&batches,
				entry.page_index,
				x0,
				y0,
				x1,
				y1,
				entry.u0,
				entry.v0,
				entry.u1,
				entry.v1,
			)
		}

		if found {
			cursor_x += entry.advance_x
			cursor_y += entry.advance_y
		}
	}

	return batches[:]
}

build_text_quads :: proc(
	renderer: ^Text_Renderer,
	text: string,
	x, y, size: f32,
	preferred_font_id: u32,
) -> []Text_Batch {
	if len(text) == 0 || renderer == nil || renderer.AtlasManager == nil {
		return nil
	}

	batches := make([dynamic]Text_Batch, 0, 16, context.temp_allocator)

	resolved_preferred_font_id := text_renderer_resolve_font_id(renderer, preferred_font_id)

	// kb_text_shape can crash for some malformed/non-normalized text streams.
	// UI/dashboard text and Nerd Font private-use symbols use the stable
	// direct glyph path with explicit fallback resolution.
	if text_is_simple_latin(text) || renderer.ShapeContext == nil {
		return build_text_quads_unshaped(renderer, text, x, y, size, resolved_preferred_font_id)
	}

	pushed_shape_fonts := text_renderer_push_shape_fonts(renderer, resolved_preferred_font_id)
	if pushed_shape_fonts > 0 {
		defer text_renderer_pop_shape_fonts(renderer, pushed_shape_fonts)
	}

	kbts.ShapeBegin(renderer.ShapeContext, .KBTS_DIRECTION_LTR, .ENGLISH)
	kbts.ShapeUtf8(renderer.ShapeContext, text, .CODEPOINT_INDEX)
	kbts.ShapeEnd(renderer.ShapeContext)

	cursor_x := x
	cursor_y := y

	for {
		run, ok := kbts.ShapeRun(renderer.ShapeContext)
		if !ok { break }
		run_font_id := text_renderer_font_id_from_run(renderer, run.Font, resolved_preferred_font_id)
		scale := fontlib.shape_scale(&renderer.AtlasManager.fonts[run_font_id].face, size)

		for {
			glyph, ok2 := kbts.GlyphIteratorNext(&run.Glyphs)
			if !ok2 { break }

			entry, found := atlas_manager_get_glyph(renderer.AtlasManager, run_font_id, size, glyph.Id)
			if !found || (entry.x1 - entry.x0) <= 0 {
				cursor_x += f32(glyph.AdvanceX) * scale
				cursor_y += f32(glyph.AdvanceY) * scale
				continue
			}

			px := cursor_x + f32(glyph.OffsetX) * scale + entry.xoff
			py := cursor_y + f32(glyph.OffsetY) * scale + entry.yoff

			px = math.floor(px + 0.5)
			py = math.floor(py + 0.5)

			x0 := px
			y0 := py
			x1 := px + (entry.xoff2 - entry.xoff)
			y1 := py + (entry.yoff2 - entry.yoff)

			s0 := entry.u0
			t0 := entry.v0
			s1 := entry.u1
			t1 := entry.v1

			text_batch_append_quad(&batches, entry.page_index, x0, y0, x1, y1, s0, t0, s1, t1)

			cursor_x += f32(glyph.AdvanceX) * scale
			cursor_y += f32(glyph.AdvanceY) * scale
		}
	}
	return batches[:]
}

draw_icon_codepoint :: proc(
	ctx: ^gpu.Gpu_Context,
	renderer: ^Text_Renderer,
	cmd: vk.CommandBuffer,
	codepoint: rune,
	x, y, w, h, size: f32,
	color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
	scissor_override: vk.Rect2D = {},
	target_extent: vk.Extent2D = {},
) {
	if codepoint == 0 || w <= 0.0 || h <= 0.0 || size <= 0.0 {
		return
	}
	icon_font_id := text_renderer_resolve_font_id(renderer, renderer.IconFont)
	if !text_font_id_valid(renderer, icon_font_id) {
		return
	}

	glyph_idx, glyph_ok := fontlib.glyph_index(&renderer.AtlasManager.fonts[icon_font_id].face, codepoint)
	if !glyph_ok {
		return
	}

	entry, found := atlas_manager_get_glyph(renderer.AtlasManager, icon_font_id, size, u16(glyph_idx))
	if !found || (entry.x1-entry.x0) <= 0 {
		return
	}

	glyph_w := entry.xoff2 - entry.xoff
	glyph_h := entry.yoff2 - entry.yoff
	px := x + (w-glyph_w)*0.5
	py := y + (h-glyph_h)*0.5
	px = math.floor(px + 0.5)
	py = math.floor(py + 0.5)

	verts := [6]Text_Vertex{
		{{px, py}, {entry.u0, entry.v0}},
		{{px + glyph_w, py + glyph_h}, {entry.u1, entry.v1}},
		{{px, py + glyph_h}, {entry.u0, entry.v1}},
		{{px, py}, {entry.u0, entry.v0}},
		{{px + glyph_w, py}, {entry.u1, entry.v0}},
		{{px + glyph_w, py + glyph_h}, {entry.u1, entry.v1}},
	}

	if renderer.AtlasManager.pending_uploads {
		fmt.println("[WARN] gpu_text: icon was not prepared before rendering")
		return
	}

	write_size := len(verts) * size_of(Text_Vertex)
	frame_slot := text_renderer_current_vertex_slot(ctx, renderer)
	vertex_buffer := &renderer.VertexBuffers[frame_slot]
	current_vertex_offset := renderer.CurrentVertexOffsets[frame_slot]
	if current_vertex_offset + write_size > int(vertex_buffer.size) {
		fmt.println("[WARN] draw_icon_codepoint: vertex buffer overflow, skipping icon")
		return
	}

	extent := target_extent
	if extent.width == 0 || extent.height == 0 {
		extent = gpu.gpu_swapchain_extent(ctx)
	}
	w_ndc := f32(extent.width)
	h_ndc := f32(extent.height)
	for i in 0 ..< len(verts) {
		verts[i].pos.x = (2.0 * verts[i].pos.x / w_ndc) - 1.0
		verts[i].pos.y = (2.0 * verts[i].pos.y / h_ndc) - 1.0
	}

	write_offset := current_vertex_offset
	libc.memcpy(
		rawptr(uintptr(vertex_buffer.cpu) + uintptr(write_offset)),
		raw_data(verts[:]),
		auto_cast write_size,
	)
	gpu.gpu_flush_buffer(vertex_buffer, u64(write_offset), u64(write_size))
	renderer.CurrentVertexOffsets[frame_slot] += write_size

	viewport := vk.Viewport {
		x = 0, y = 0,
		width = w_ndc, height = h_ndc,
		minDepth = 0.0, maxDepth = 1.0,
	}
	scissor := vk.Rect2D{offset = {0, 0}, extent = extent}
	if scissor_override.extent.width > 0 && scissor_override.extent.height > 0 {
		scissor = scissor_override
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)
	vk.CmdSetScissor(cmd, 0, 1, &scissor)

	page := &renderer.AtlasManager.pages[entry.page_index]
	push_constants := Text_Push_Constants{
		color         = color,
		texture_index = page.texture_index,
		sampler_index = renderer.SamplerIndex,
	}
	vk.CmdBindPipeline(cmd, .GRAPHICS, renderer.Pipeline.Pipeline)
	bindless_set := gpu.gpu_bindless_set(ctx)
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, renderer.Pipeline.Layout, 0, 1, &bindless_set, 0, nil)
	vk.CmdPushConstants(cmd, renderer.Pipeline.Layout, {.FRAGMENT}, 0, auto_cast size_of(Text_Push_Constants), &push_constants)

	offset: vk.DeviceSize = auto_cast write_offset
	vk.CmdBindVertexBuffers(cmd, 0, 1, &vertex_buffer.buffer, &offset)
	vk.CmdDraw(cmd, auto_cast len(verts), 1, 0, 0)
}
