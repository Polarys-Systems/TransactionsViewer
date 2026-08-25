package gpu_text

// Glyph atlas paging, rasterization, and upload tracking.

import "base:runtime"
import "core:fmt"
import "core:math"

import fontlib "../font"
import gpu "../gpu"

atlas_page_width  :: 2048
atlas_page_height :: 2048
atlas_oversample  :: 1
max_atlas_pages   :: 16
atlas_size_quantization :: f32(64.0)

// ------------------------------------------------------------------

Atlas_Glyph :: struct {
	page_index: int,
	x0, y0, x1, y1: i32,
	u0, v0, u1, v1: f32,
	xoff, yoff:     f32,
	xoff2, yoff2:   f32,
	advance_x:      f32,
	advance_y:      f32,
}

// ------------------------------------------------------------------

Shelf_Packer :: struct {
	x, y:       i32,
	row_height: i32,
}

pack_glyph :: proc(p: ^Shelf_Packer, w, h, atlas_w, atlas_h: i32) -> (x, y: i32, ok: bool) {
	if w > atlas_w || h > atlas_h {
		return 0, 0, false
	}
	if p.x + w > atlas_w {
		p.x = 0
		p.y += p.row_height + 1
		p.row_height = 0
	}
	if p.y + h > atlas_h {
		return 0, 0, false
	}
	x, y = p.x, p.y
	p.x += w + 1
	if h > p.row_height {
		p.row_height = h
	}
	return x, y, true
}

// ------------------------------------------------------------------

Atlas_Page :: struct {
	texture:       gpu.Gpu_Texture_Handle,
	texture_index: u32,
	packer:        Shelf_Packer,
}

// ------------------------------------------------------------------

Font_Entry :: struct {
	id:   u32,
	face: fontlib.Face,
}

// ------------------------------------------------------------------

Glyph_Key :: struct {
	font_id:  u32,
	size_64:  u32,
	glyph_id: u16,
}

Font_Size_Key :: struct {
	font_id: u32,
	size_64: u32,
}

// ------------------------------------------------------------------

Atlas_Manager :: struct {
	ctx:               ^gpu.Gpu_Context,
	pages:             [dynamic]Atlas_Page,
	fonts:             [dynamic]Font_Entry,
	cache:             map[Glyph_Key]Atlas_Glyph,
	line_metrics_cache: map[Font_Size_Key]fontlib.Line_Metrics,
	next_font_id:      u32,
	pending_uploads:   bool,
	allocator:         runtime.Allocator,
}

// ------------------------------------------------------------------

create_atlas_manager :: proc(
	ctx: ^gpu.Gpu_Context,
	allocator := context.allocator,
) -> ^Atlas_Manager {
	manager := new(Atlas_Manager, allocator)
	manager.ctx = ctx
	manager.allocator = allocator
	manager.pages = make([dynamic]Atlas_Page, allocator)
	manager.fonts = make([dynamic]Font_Entry, allocator)
	manager.cache = make(map[Glyph_Key]Atlas_Glyph, 1024, allocator)
	manager.line_metrics_cache = make(map[Font_Size_Key]fontlib.Line_Metrics, 128, allocator)
	return manager
}

// ------------------------------------------------------------------

destroy_atlas_manager :: proc(manager: ^Atlas_Manager) {
	if manager == nil {
		return
	}

	for &page in manager.pages {
		gpu.gpu_destroy_texture(manager.ctx, page.texture)
	}
	delete(manager.pages)

	for &font in manager.fonts {
		fontlib.face_destroy(&font.face, manager.allocator)
	}
	delete(manager.fonts)

	delete(manager.cache)
	delete(manager.line_metrics_cache)

	free(manager, manager.allocator)
}

// ------------------------------------------------------------------

atlas_manager_register_font :: proc(manager: ^Atlas_Manager, font_data: []byte) -> (u32, bool) {
	font: Font_Entry
	font.id = manager.next_font_id
	face, ok := fontlib.face_load_from_data(font.id, font_data, "", manager.allocator)
	if !ok {
		return 0, false
	}
	font.face = face

	append(&manager.fonts, font)
	manager.next_font_id += 1
	return font.id, true
}

// ------------------------------------------------------------------

atlas_manager_unregister_last_font :: proc(manager: ^Atlas_Manager, font_id: u32) -> bool {
	if manager == nil || len(manager.fonts) == 0 {
		return false
	}
	if manager.next_font_id == 0 || font_id+1 != manager.next_font_id {
		return false
	}

	last_idx := len(manager.fonts) - 1
	last_font := manager.fonts[last_idx]
	if last_font.id != font_id {
		return false
	}

	removed := pop(&manager.fonts)
	fontlib.face_destroy(&removed.face, manager.allocator)
	manager.next_font_id -= 1
	return true
}

// ------------------------------------------------------------------

atlas_quantize_size_64 :: proc(size: f32) -> u32 {
	quantized := i32(math.round(f64(size * atlas_size_quantization)))
	if quantized < 1 {
		quantized = 1
	}
	return u32(quantized)
}

atlas_size_from_quantized_64 :: proc(size_64: u32) -> f32 {
	return f32(size_64) / atlas_size_quantization
}

// ------------------------------------------------------------------

rasterize_glyph :: proc(font: ^Font_Entry, size: f32, glyph_id: u16) -> (
	bitmap: []byte,
	bw, bh: i32,
	xoff, yoff: f32,
	advance_x, advance_y: f32,
	ok: bool,
) {
	glyph, rasterized := fontlib.rasterize_glyph(&font.face, size, i32(glyph_id), context.temp_allocator)
	if !rasterized {
		return nil, 0, 0, 0, 0, 0, 0, false
	}
	return glyph.pixels, glyph.width, glyph.height, glyph.xoff, glyph.yoff, glyph.advance_x, glyph.advance_y, true
}

// ------------------------------------------------------------------

create_atlas_page :: proc(manager: ^Atlas_Manager) -> (int, bool) {
	if len(manager.pages) >= max_atlas_pages {
		return 0, false
	}

	page: Atlas_Page
	zero_pixels := make([]u8, atlas_page_width * atlas_page_height, context.temp_allocator)
	page.texture = gpu.gpu_create_texture(
		manager.ctx,
		gpu.Gpu_Texture_Desc{
			width  = u32(atlas_page_width),
			height = u32(atlas_page_height),
			format = .R8_UNORM,
			usage  = {.SAMPLED},
		},
		zero_pixels,
	)
	page_tex_idx, ok := gpu.gpu_texture_descriptor_index(manager.ctx, page.texture)
	if !ok {
		gpu.gpu_destroy_texture(manager.ctx, page.texture)
		return 0, false
	}
	page.texture_index = page_tex_idx

	append(&manager.pages, page)
	return len(manager.pages) - 1, true
}

// ------------------------------------------------------------------

enqueue_glyph_upload :: proc(
	manager: ^Atlas_Manager, page_idx: int, bitmap: []byte,
	bw, bh, ax, ay: i32, xoff, yoff, advance_x, advance_y: f32, key: Glyph_Key,
) -> (Atlas_Glyph, bool) {
	if page_idx < 0 || page_idx >= len(manager.pages) {
		return {}, false
	}

	page := &manager.pages[page_idx]
	gpu.gpu_upload_enqueue_texture_copy(
		manager.ctx,
		page.texture,
		gpu.Gpu_Image_Upload_Desc{
			region = gpu.Gpu_Texture_Update_Region{
				x      = u32(ax),
				y      = u32(ay),
				width  = u32(bw),
				height = u32(bh),
			},
			final_layout = .SHADER_READ_ONLY_OPTIMAL,
			update_descriptor = true,
		},
		bitmap,
	)
	manager.pending_uploads = true

	glyph := Atlas_Glyph{
		page_index = page_idx,
		x0 = ax,
		y0 = ay,
		x1 = ax + bw,
		y1 = ay + bh,
		u0 = f32(ax) / f32(atlas_page_width),
		v0 = f32(ay) / f32(atlas_page_height),
		u1 = f32(ax + bw) / f32(atlas_page_width),
		v1 = f32(ay + bh) / f32(atlas_page_height),
		xoff = xoff,
		yoff = yoff,
		xoff2 = xoff + f32(bw) / f32(atlas_oversample),
		yoff2 = yoff + f32(bh) / f32(atlas_oversample),
		advance_x = advance_x,
		advance_y = advance_y,
	}
	manager.cache[key] = glyph
	return glyph, true
}

atlas_manager_get_line_metrics :: proc(manager: ^Atlas_Manager, font_id: u32, size: f32) -> fontlib.Line_Metrics {
	if manager == nil || int(font_id) >= len(manager.fonts) {
		return fontlib.Line_Metrics{line_height = max(1.0, size), ascent = size * 0.8, descent = -size * 0.2}
	}
	size_64 := atlas_quantize_size_64(size)
	key := Font_Size_Key{font_id = font_id, size_64 = size_64}
	if metrics, ok := manager.line_metrics_cache[key]; ok {
		return metrics
	}
	raster_size := atlas_size_from_quantized_64(size_64)
	metrics := fontlib.line_metrics(&manager.fonts[font_id].face, raster_size)
	manager.line_metrics_cache[key] = metrics
	return metrics
}

atlas_manager_get_glyph :: proc(
	manager: ^Atlas_Manager,
	font_id: u32,
	size: f32,
	glyph_id: u16,
) -> (Atlas_Glyph, bool) {
	size_64 := atlas_quantize_size_64(size)
	key := Glyph_Key{font_id = font_id, size_64 = size_64, glyph_id = glyph_id}
	if glyph, ok := manager.cache[key]; ok {
		return glyph, true
	}

	if int(font_id) >= len(manager.fonts) {
		fmt.printf("[WARN] AtlasManager: invalid font_id %d\n", font_id)
		return {}, false
	}
	font := &manager.fonts[font_id]

	raster_size := atlas_size_from_quantized_64(size_64)
	bitmap, bw, bh, xoff, yoff, advance_x, advance_y, raster_ok := rasterize_glyph(font, raster_size, glyph_id)
	if !raster_ok {
		manager.cache[key] = {}
		return {}, false
	}
	if bw <= 0 || bh <= 0 {
		glyph := Atlas_Glyph{
			page_index = -1,
			advance_x = advance_x,
			advance_y = advance_y,
		}
		manager.cache[key] = glyph
		return glyph, true
	}

	// Try to pack into existing pages
	for i in 0 ..< len(manager.pages) {
		page := &manager.pages[i]
		ax, ay, ok := pack_glyph(&page.packer, bw, bh, atlas_page_width, atlas_page_height)
		if ok {
			return enqueue_glyph_upload(manager, i, bitmap, bw, bh, ax, ay, xoff, yoff, advance_x, advance_y, key)
		}
	}

	// Need a new page
	page_idx, ok := create_atlas_page(manager)
	if !ok {
		fmt.println("[WARN] AtlasManager: failed to create new atlas page")
		return {}, false
	}

	page := &manager.pages[page_idx]
	ax, ay, packed := pack_glyph(&page.packer, bw, bh, atlas_page_width, atlas_page_height)
	if !packed {
		fmt.println("[WARN] AtlasManager: glyph too large for empty atlas page")
		return {}, false
	}

	return enqueue_glyph_upload(manager, page_idx, bitmap, bw, bh, ax, ay, xoff, yoff, advance_x, advance_y, key)
}
