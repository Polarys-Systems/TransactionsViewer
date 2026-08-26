package gpu_text

import "core:fmt"
import "core:math"
import "core:os"

import fontlib "../font"
import gpu "../gpu"

Glyph_Quad :: struct {
	top_left:        [2]f32,
	bottom_right:    [2]f32,
	top_left_uv:     [2]f32,
	bottom_right_uv: [2]f32,
	texture_index:   u32,
}

Text_Renderer :: struct {
	AtlasManager:  ^Atlas_Manager,
	DefaultFont:   u32,
	IconFont:      u32,
	FallbackFonts: [dynamic]u32,
}

text_font_id_valid :: proc(renderer: ^Text_Renderer, font_id: u32) -> bool {
	return renderer != nil &&
	       renderer.AtlasManager != nil &&
	       int(font_id) < len(renderer.AtlasManager.fonts)
}

text_renderer_resolve_font_id :: proc(renderer: ^Text_Renderer, requested: u32) -> u32 {
	if text_font_id_valid(renderer, requested) {
		return requested
	}
	if renderer != nil && text_font_id_valid(renderer, renderer.DefaultFont) {
		return renderer.DefaultFont
	}
	if renderer != nil && renderer.AtlasManager != nil && len(renderer.AtlasManager.fonts) > 0 {
		return renderer.AtlasManager.fonts[0].id
	}
	return 0
}

text_renderer_register_font_data :: proc(renderer: ^Text_Renderer, font_data: []byte) -> (u32, bool) {
	if renderer == nil || renderer.AtlasManager == nil || len(font_data) == 0 {
		return 0, false
	}
	return atlas_manager_register_font(renderer.AtlasManager, font_data)
}

text_renderer_register_font :: proc(
	renderer: ^Text_Renderer,
	font_path: string,
	allocator := context.allocator,
) -> (font_id: u32, ok: bool) {
	font_data, err := os.read_entire_file(font_path, allocator)
	if err != nil {
		fmt.printf("[WARN] text_renderer_register_font: failed to load %q\n", font_path)
		return 0, false
	}
	defer delete(font_data, allocator)
	return text_renderer_register_font_data(renderer, font_data)
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

text_resolve_glyph :: proc(
	renderer: ^Text_Renderer,
	preferred_font_id: u32,
	codepoint: rune,
) -> (font_id: u32, glyph_index: i32, ok: bool) {
	preferred := text_renderer_resolve_font_id(renderer, preferred_font_id)
	if text_font_id_valid(renderer, preferred) {
		if index, found := fontlib.glyph_index(&renderer.AtlasManager.fonts[preferred].face, codepoint); found {
			return preferred, index, true
		}
	}
	for fallback in renderer.FallbackFonts {
		if fallback == preferred || !text_font_id_valid(renderer, fallback) {
			continue
		}
		if index, found := fontlib.glyph_index(&renderer.AtlasManager.fonts[fallback].face, codepoint); found {
			return fallback, index, true
		}
	}
	if codepoint != '?' {
		return text_resolve_glyph(renderer, preferred, '?')
	}
	return 0, 0, false
}

text_renderer_prepare :: proc(
	renderer: ^Text_Renderer,
	text: string,
	size: f32,
	font_id: u32,
) -> bool {
	if renderer == nil || size <= 0 || len(text) == 0 {
		return false
	}
	prepared := false
	for codepoint in text {
		if codepoint == '\r' || codepoint == '\n' {
			continue
		}
		glyph_font, glyph_index, found := text_resolve_glyph(renderer, font_id, codepoint)
		if !found {
			continue
		}
		_, found = atlas_manager_get_glyph(renderer.AtlasManager, glyph_font, size, u16(glyph_index))
		prepared = prepared || found
	}
	return prepared
}

text_renderer_prepare_default :: proc(renderer: ^Text_Renderer, text: string, size: f32) -> bool {
	if renderer == nil {
		return false
	}
	return text_renderer_prepare(renderer, text, size, renderer.DefaultFont)
}

text_renderer_prepare_icon :: proc(renderer: ^Text_Renderer, codepoint: rune, size: f32) -> bool {
	if renderer == nil || codepoint == 0 || size <= 0 {
		return false
	}
	font_id := text_renderer_resolve_font_id(renderer, renderer.IconFont)
	glyph_index, found := fontlib.glyph_index(&renderer.AtlasManager.fonts[font_id].face, codepoint)
	if !found {
		return false
	}
	_, found = atlas_manager_get_glyph(renderer.AtlasManager, font_id, size, u16(glyph_index))
	return found
}

text_renderer_upload :: proc(ctx: ^gpu.Gpu_Context, renderer: ^Text_Renderer) {
	if renderer == nil || renderer.AtlasManager == nil || !renderer.AtlasManager.pending_uploads {
		return
	}
	gpu.gpu_upload_flush(ctx)
	renderer.AtlasManager.pending_uploads = false
}

create_text_renderer :: proc(ctx: ^gpu.Gpu_Context, allocator := context.allocator) -> Text_Renderer {
	renderer := Text_Renderer{
		AtlasManager = create_atlas_manager(ctx, allocator),
		FallbackFonts = make([dynamic]u32, 0, 8, allocator),
	}
	return renderer
}

destroy_text_renderer :: proc(ctx: ^gpu.Gpu_Context, renderer: ^Text_Renderer) {
	if renderer == nil {
		return
	}
	destroy_atlas_manager(renderer.AtlasManager)
	delete(renderer.FallbackFonts)
	renderer^ = {}
}

text_measure_width_for_font :: proc(renderer: ^Text_Renderer, text: string, size: f32, font_id: u32) -> f32 {
	if renderer == nil || size <= 0 || len(text) == 0 {
		return 0
	}
	raster_size := atlas_size_from_quantized_64(atlas_quantize_size_64(size))
	line_width, max_width: f32
	for codepoint in text {
		if codepoint == '\r' {
			continue
		}
		if codepoint == '\n' {
			max_width = max(max_width, line_width)
			line_width = 0
			continue
		}
		glyph_font, glyph_index, found := text_resolve_glyph(renderer, font_id, codepoint)
		if found {
			line_width += fontlib.glyph_advance(
				&renderer.AtlasManager.fonts[glyph_font].face,
				glyph_index,
				raster_size,
			)
		}
	}
	return max(max_width, line_width)
}

measure_text_width :: proc(renderer: ^Text_Renderer, text: string, size: f32, font_id: u32) -> f32 {
	return text_measure_width_for_font(renderer, text, size, font_id)
}

measure_text_height :: proc(renderer: ^Text_Renderer, size: f32, font_id: u32) -> f32 {
	if renderer == nil || size <= 0 {
		return 0
	}
	resolved := text_renderer_resolve_font_id(renderer, font_id)
	if !text_font_id_valid(renderer, resolved) {
		return 0
	}
	return atlas_manager_get_line_metrics(renderer.AtlasManager, resolved, size).line_height
}

text_baseline_offset :: proc(renderer: ^Text_Renderer, size: f32) -> f32 {
	if renderer == nil {
		return 0
	}
	return text_baseline_offset_for_font(renderer, renderer.DefaultFont, size)
}

text_baseline_offset_for_font :: proc(renderer: ^Text_Renderer, font_id: u32, size: f32) -> f32 {
	if renderer == nil || size <= 0 {
		return 0
	}
	resolved := text_renderer_resolve_font_id(renderer, font_id)
	if !text_font_id_valid(renderer, resolved) {
		return 0
	}
	return atlas_manager_get_line_metrics(renderer.AtlasManager, resolved, size).ascent
}

text_renderer_can_draw_icon_codepoint :: proc(renderer: ^Text_Renderer, codepoint: rune) -> bool {
	if renderer == nil || codepoint == 0 {
		return false
	}
	font_id := text_renderer_resolve_font_id(renderer, renderer.IconFont)
	_, ok := fontlib.glyph_index(&renderer.AtlasManager.fonts[font_id].face, codepoint)
	return ok
}

text_build_quads :: proc(
	renderer: ^Text_Renderer,
	text: string,
	x, y, size: f32,
	font_id: u32,
) -> []Glyph_Quad {
	if renderer == nil || size <= 0 || len(text) == 0 {
		return nil
	}
	quads := make([dynamic]Glyph_Quad, 0, len(text), context.temp_allocator)
	resolved := text_renderer_resolve_font_id(renderer, font_id)
	line_advance := atlas_manager_get_line_metrics(renderer.AtlasManager, resolved, size).line_height
	cursor_x, cursor_y := x, y

	for codepoint in text {
		if codepoint == '\r' {
			continue
		}
		if codepoint == '\n' {
			cursor_x = x
			cursor_y += max(line_advance, size)
			continue
		}
		glyph_font, glyph_index, found := text_resolve_glyph(renderer, resolved, codepoint)
		if !found {
			continue
		}
		entry, cached := atlas_manager_get_glyph(renderer.AtlasManager, glyph_font, size, u16(glyph_index))
		if !cached {
			continue
		}
		if entry.page_index >= 0 && entry.x1 > entry.x0 {
			px := math.floor(cursor_x + entry.xoff + 0.5)
			py := math.floor(cursor_y + entry.yoff + 0.5)
			append(&quads, Glyph_Quad{
				top_left = {px, py},
				bottom_right = {px + entry.xoff2-entry.xoff, py + entry.yoff2-entry.yoff},
				top_left_uv = {entry.u0, entry.v0},
				bottom_right_uv = {entry.u1, entry.v1},
				texture_index = renderer.AtlasManager.pages[entry.page_index].texture_index,
			})
		}
		cursor_x += entry.advance_x
		cursor_y += entry.advance_y
	}
	return quads[:]
}

text_build_icon_quad :: proc(
	renderer: ^Text_Renderer,
	codepoint: rune,
	x, y, width, height, size: f32,
) -> (Glyph_Quad, bool) {
	if renderer == nil || codepoint == 0 || width <= 0 || height <= 0 || size <= 0 {
		return {}, false
	}
	font_id := text_renderer_resolve_font_id(renderer, renderer.IconFont)
	glyph_index, found := fontlib.glyph_index(&renderer.AtlasManager.fonts[font_id].face, codepoint)
	if !found {
		return {}, false
	}
	entry, cached := atlas_manager_get_glyph(renderer.AtlasManager, font_id, size, u16(glyph_index))
	if !cached || entry.page_index < 0 || entry.x1 <= entry.x0 {
		return {}, false
	}
	glyph_width := entry.xoff2 - entry.xoff
	glyph_height := entry.yoff2 - entry.yoff
	px := math.floor(x + (width-glyph_width)*0.5 + 0.5)
	py := math.floor(y + (height-glyph_height)*0.5 + 0.5)
	return Glyph_Quad{
		top_left = {px, py},
		bottom_right = {px + glyph_width, py + glyph_height},
		top_left_uv = {entry.u0, entry.v0},
		bottom_right_uv = {entry.u1, entry.v1},
		texture_index = renderer.AtlasManager.pages[entry.page_index].texture_index,
	}, true
}
