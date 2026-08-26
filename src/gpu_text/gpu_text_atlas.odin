package gpu_text

import "base:runtime"
import "core:fmt"
import "core:math"

import fontlib "../font"
import gpu "../gpu"

atlas_page_width  :: 2048
atlas_page_height :: 2048
atlas_padding     :: 1
max_atlas_pages   :: 16
atlas_size_quantization :: f32(64.0)

Atlas_Glyph_State :: enum u8 {
	Metrics,
	Resident,
	Bitmapless,
	Failed,
}

Atlas_Glyph :: struct {
	state:             Atlas_Glyph_State,
	page_index:        int,
	texture_index:     u32,
	x0, y0, x1, y1:   i32,
	u0, v0, u1, v1:   f32,
	xoff, yoff:        f32,
	xoff2, yoff2:      f32,
	advance_x:         f32,
	advance_y:         f32,
}

Shelf_Packer :: struct {
	x, y:       i32,
	row_height: i32,
}

pack_glyph :: proc(p: ^Shelf_Packer, w, h, atlas_w, atlas_h: i32) -> (x, y: i32, ok: bool) {
	if p == nil || w <= 0 || h <= 0 || w > atlas_w || h > atlas_h {
		return 0, 0, false
	}
	next := p^
	if next.x + w > atlas_w {
		next.x = 0
		next.y += next.row_height
		next.row_height = 0
	}
	if next.y + h > atlas_h {
		return 0, 0, false
	}
	x, y = next.x, next.y
	next.x += w
	next.row_height = max(next.row_height, h)
	p^ = next
	return x, y, true
}

Atlas_Page :: struct {
	texture:       gpu.Gpu_Texture_Handle,
	texture_index: u32,
	packer:        Shelf_Packer,
}

Font_Entry :: struct {
	id:   u32,
	face: fontlib.Face,
}

Glyph_Key :: struct {
	font_id:  u32,
	size_64:  u32,
	glyph_id: u16,
}

Font_Size_Key :: struct {
	font_id: u32,
	size_64: u32,
}

Atlas_Manager :: struct {
	ctx:                ^gpu.Gpu_Context,
	pages:              [dynamic]Atlas_Page,
	fonts:              [dynamic]Font_Entry,
	glyphs:             map[Glyph_Key]Atlas_Glyph,
	line_metrics_cache: map[Font_Size_Key]fontlib.Line_Metrics,
	next_font_id:       u32,
	allocator:          runtime.Allocator,
}

create_atlas_manager :: proc(ctx: ^gpu.Gpu_Context, allocator := context.allocator) -> ^Atlas_Manager {
	manager := new(Atlas_Manager, allocator)
	manager.ctx = ctx
	manager.allocator = allocator
	manager.pages = make([dynamic]Atlas_Page, allocator)
	manager.fonts = make([dynamic]Font_Entry, allocator)
	manager.glyphs = make(map[Glyph_Key]Atlas_Glyph, 1024, allocator)
	manager.line_metrics_cache = make(map[Font_Size_Key]fontlib.Line_Metrics, 128, allocator)
	return manager
}

destroy_atlas_manager :: proc(manager: ^Atlas_Manager) {
	if manager == nil {
		return
	}
	for &page in manager.pages {
		gpu.gpu_destroy_texture(manager.ctx, page.texture)
	}
	for &font in manager.fonts {
		fontlib.face_destroy(&font.face, manager.allocator)
	}
	delete(manager.pages)
	delete(manager.fonts)
	delete(manager.glyphs)
	delete(manager.line_metrics_cache)
	free(manager, manager.allocator)
}

atlas_manager_register_font :: proc(manager: ^Atlas_Manager, font_data: []byte) -> (u32, bool) {
	if manager == nil || len(font_data) == 0 {
		return 0, false
	}
	font_id := manager.next_font_id
	face, ok := fontlib.face_load_from_data(font_id, font_data, "", manager.allocator)
	if !ok {
		return 0, false
	}
	append(&manager.fonts, Font_Entry{id = font_id, face = face})
	manager.next_font_id += 1
	return font_id, true
}

atlas_quantize_size_64 :: proc(size: f32) -> u32 {
	quantized := i32(math.round(f64(size * atlas_size_quantization)))
	return u32(max(quantized, 1))
}

atlas_size_from_quantized_64 :: proc(size_64: u32) -> f32 {
	return f32(size_64) / atlas_size_quantization
}

atlas_manager_get_line_metrics :: proc(
	manager: ^Atlas_Manager,
	font_id, size_64: u32,
) -> fontlib.Line_Metrics {
	if manager == nil || int(font_id) >= len(manager.fonts) {
		size := atlas_size_from_quantized_64(size_64)
		return fontlib.Line_Metrics{
			ascent = size * 0.8,
			descent = -size * 0.2,
			line_height = max(1.0, size),
		}
	}
	key := Font_Size_Key{font_id = font_id, size_64 = size_64}
	if metrics, ok := manager.line_metrics_cache[key]; ok {
		return metrics
	}
	metrics := fontlib.line_metrics(&manager.fonts[font_id].face, size_64)
	manager.line_metrics_cache[key] = metrics
	return metrics
}

atlas_manager_get_glyph_metrics :: proc(
	manager: ^Atlas_Manager,
	font_id, size_64: u32,
	glyph_id: u16,
) -> (Atlas_Glyph, bool) {
	if manager == nil || int(font_id) >= len(manager.fonts) || glyph_id == 0 {
		return {}, false
	}
	key := Glyph_Key{font_id = font_id, size_64 = size_64, glyph_id = glyph_id}
	if glyph, ok := manager.glyphs[key]; ok {
		return glyph, glyph.state != .Failed
	}
	advance_x, ok := fontlib.glyph_advance(&manager.fonts[font_id].face, i32(glyph_id), size_64)
	if !ok {
		manager.glyphs[key] = Atlas_Glyph{state = .Failed, page_index = -1}
		return {}, false
	}
	glyph := Atlas_Glyph{
		state = .Metrics,
		page_index = -1,
		advance_x = advance_x,
	}
	manager.glyphs[key] = glyph
	return glyph, true
}

create_atlas_page :: proc(manager: ^Atlas_Manager) -> (int, bool) {
	if manager == nil || manager.ctx == nil || len(manager.pages) >= max_atlas_pages {
		return 0, false
	}
	texture := gpu.gpu_create_texture_deferred(manager.ctx, gpu.Gpu_Texture_Desc{
		width = atlas_page_width,
		height = atlas_page_height,
		format = .R8_UNORM,
		usage = {.SAMPLED},
	})
	texture_index, ok := gpu.gpu_texture_descriptor_index(manager.ctx, texture)
	if !ok {
		gpu.gpu_destroy_texture(manager.ctx, texture)
		return 0, false
	}
	append(&manager.pages, Atlas_Page{
		texture = texture,
		texture_index = texture_index,
	})
	return len(manager.pages) - 1, true
}

atlas_manager_pack :: proc(manager: ^Atlas_Manager, width, height: i32) -> (page, x, y: int, ok: bool) {
	for i in 0..<len(manager.pages) {
		ax, ay, packed := pack_glyph(
			&manager.pages[i].packer,
			width,
			height,
			atlas_page_width,
			atlas_page_height,
		)
		if packed {
			return i, int(ax), int(ay), true
		}
	}
	page_index, created := create_atlas_page(manager)
	if !created {
		return 0, 0, 0, false
	}
	ax, ay, packed := pack_glyph(
		&manager.pages[page_index].packer,
		width,
		height,
		atlas_page_width,
		atlas_page_height,
	)
	return page_index, int(ax), int(ay), packed
}

atlas_manager_get_glyph :: proc(
	manager: ^Atlas_Manager,
	font_id, size_64: u32,
	glyph_id: u16,
) -> (Atlas_Glyph, bool) {
	metrics, ok := atlas_manager_get_glyph_metrics(manager, font_id, size_64, glyph_id)
	if !ok {
		return {}, false
	}
	if metrics.state == .Resident || metrics.state == .Bitmapless {
		return metrics, true
	}

	key := Glyph_Key{font_id = font_id, size_64 = size_64, glyph_id = glyph_id}
	bitmap, rasterized := fontlib.rasterize_glyph(
		&manager.fonts[font_id].face,
		size_64,
		i32(glyph_id),
		context.temp_allocator,
	)
	if !rasterized {
		manager.glyphs[key] = Atlas_Glyph{state = .Failed, page_index = -1}
		return {}, false
	}
	metrics.advance_x = bitmap.advance_x
	metrics.advance_y = bitmap.advance_y
	if bitmap.width <= 0 || bitmap.height <= 0 {
		metrics.state = .Bitmapless
		metrics.page_index = -1
		manager.glyphs[key] = metrics
		return metrics, true
	}

	padded_width := bitmap.width + 2 * atlas_padding
	padded_height := bitmap.height + 2 * atlas_padding
	page_index, packed_x, packed_y, packed := atlas_manager_pack(manager, padded_width, padded_height)
	if !packed {
		fmt.println("[WARN] AtlasManager: no room for glyph")
		manager.glyphs[key] = Atlas_Glyph{state = .Failed, page_index = -1}
		return {}, false
	}

	padded := make([]byte, int(padded_width*padded_height), context.temp_allocator)
	for row := 0; row < int(bitmap.height); row += 1 {
		src_start := row * int(bitmap.width)
		dst_start := (row + atlas_padding) * int(padded_width) + atlas_padding
		copy(
			padded[dst_start:dst_start+int(bitmap.width)],
			bitmap.pixels[src_start:src_start+int(bitmap.width)],
		)
	}

	page := &manager.pages[page_index]
	gpu.gpu_upload_enqueue_texture_copy(
		manager.ctx,
		page.texture,
		gpu.Gpu_Image_Upload_Desc{
			region = {
				x = u32(packed_x),
				y = u32(packed_y),
				width = u32(padded_width),
				height = u32(padded_height),
			},
			final_layout = .SHADER_READ_ONLY_OPTIMAL,
		},
		padded,
	)

	x0 := i32(packed_x) + atlas_padding
	y0 := i32(packed_y) + atlas_padding
	metrics.state = .Resident
	metrics.page_index = page_index
	metrics.texture_index = page.texture_index
	metrics.x0 = x0
	metrics.y0 = y0
	metrics.x1 = x0 + bitmap.width
	metrics.y1 = y0 + bitmap.height
	metrics.u0 = f32(metrics.x0) / f32(atlas_page_width)
	metrics.v0 = f32(metrics.y0) / f32(atlas_page_height)
	metrics.u1 = f32(metrics.x1) / f32(atlas_page_width)
	metrics.v1 = f32(metrics.y1) / f32(atlas_page_height)
	metrics.xoff = bitmap.xoff
	metrics.yoff = bitmap.yoff
	metrics.xoff2 = bitmap.xoff + f32(bitmap.width)
	metrics.yoff2 = bitmap.yoff + f32(bitmap.height)
	manager.glyphs[key] = metrics
	return metrics, true
}
