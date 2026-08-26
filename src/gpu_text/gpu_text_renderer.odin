package gpu_text

import "core:fmt"
import "core:os"

import fontlib "../font"
import gpu "../gpu"

Glyph_Resolve_Key :: struct {
	preferred_font: u32,
	codepoint:      rune,
}

Resolved_Glyph :: struct {
	font_id:  u32,
	glyph_id: u16,
	found:    bool,
}

Text_Renderer :: struct {
	AtlasManager:  ^Atlas_Manager,
	FallbackFonts: [dynamic]u32,
	resolve_cache: map[Glyph_Resolve_Key]Resolved_Glyph,
}

Text_Font :: struct {
	Renderer: ^Text_Renderer,
	FontID:   u32,
	Size64:   u32,
	Size:     f32,
	Metrics:  fontlib.Line_Metrics,
}

text_font_id_valid :: #force_inline proc(renderer: ^Text_Renderer, font_id: u32) -> bool {
	return renderer != nil &&
	       renderer.AtlasManager != nil &&
	       int(font_id) < len(renderer.AtlasManager.fonts)
}

text_renderer_create :: proc(ctx: ^gpu.Gpu_Context, allocator := context.allocator) -> Text_Renderer {
	return Text_Renderer{
		AtlasManager = create_atlas_manager(ctx, allocator),
		FallbackFonts = make([dynamic]u32, 0, 8, allocator),
		resolve_cache = make(map[Glyph_Resolve_Key]Resolved_Glyph, 512, allocator),
	}
}

text_renderer_destroy :: proc(renderer: ^Text_Renderer) {
	if renderer == nil {
		return
	}
	destroy_atlas_manager(renderer.AtlasManager)
	delete(renderer.FallbackFonts)
	delete(renderer.resolve_cache)
	renderer^ = {}
}

text_renderer_register_font_data :: proc(renderer: ^Text_Renderer, font_data: []byte) -> (u32, bool) {
	if renderer == nil || renderer.AtlasManager == nil {
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

text_renderer_set_fallback_fonts :: proc(renderer: ^Text_Renderer, font_ids: []u32) {
	if renderer == nil {
		return
	}
	clear(&renderer.FallbackFonts)
	for font_id in font_ids {
		if !text_font_id_valid(renderer, font_id) {
			continue
		}
		duplicate := false
		for existing in renderer.FallbackFonts {
			if existing == font_id {
				duplicate = true
				break
			}
		}
		if !duplicate {
			append(&renderer.FallbackFonts, font_id)
		}
	}
	clear(&renderer.resolve_cache)
}

text_font_create :: proc(renderer: ^Text_Renderer, font_id: u32, size: f32) -> (Text_Font, bool) {
	if !text_font_id_valid(renderer, font_id) || size <= 0 {
		return {}, false
	}
	size_64 := atlas_quantize_size_64(size)
	return Text_Font{
		Renderer = renderer,
		FontID = font_id,
		Size64 = size_64,
		Size = atlas_size_from_quantized_64(size_64),
		Metrics = atlas_manager_get_line_metrics(renderer.AtlasManager, font_id, size_64),
	}, true
}

text_resolve_glyph :: proc(font: ^Text_Font, codepoint: rune) -> Resolved_Glyph {
	if font == nil || font.Renderer == nil {
		return {}
	}
	renderer := font.Renderer
	key := Glyph_Resolve_Key{preferred_font = font.FontID, codepoint = codepoint}
	if resolved, ok := renderer.resolve_cache[key]; ok {
		return resolved
	}

	glyph_index, found := fontlib.glyph_index(
		&renderer.AtlasManager.fonts[font.FontID].face,
		codepoint,
	)
	if found && glyph_index <= 0xffff {
		resolved := Resolved_Glyph{
			font_id = font.FontID,
			glyph_id = u16(glyph_index),
			found = true,
		}
		renderer.resolve_cache[key] = resolved
		return resolved
	}
	for fallback in renderer.FallbackFonts {
		if fallback == font.FontID || !text_font_id_valid(renderer, fallback) {
			continue
		}
		glyph_index, found = fontlib.glyph_index(
			&renderer.AtlasManager.fonts[fallback].face,
			codepoint,
		)
		if found && glyph_index <= 0xffff {
			resolved := Resolved_Glyph{
				font_id = fallback,
				glyph_id = u16(glyph_index),
				found = true,
			}
			renderer.resolve_cache[key] = resolved
			return resolved
		}
	}

	if codepoint != '?' {
		resolved := text_resolve_glyph(font, '?')
		renderer.resolve_cache[key] = resolved
		return resolved
	}
	renderer.resolve_cache[key] = {}
	return {}
}

text_font_get_glyph :: proc(font: ^Text_Font, codepoint: rune) -> (Atlas_Glyph, bool) {
	resolved := text_resolve_glyph(font, codepoint)
	if !resolved.found {
		return {}, false
	}
	return atlas_manager_get_glyph(
		font.Renderer.AtlasManager,
		resolved.font_id,
		font.Size64,
		resolved.glyph_id,
	)
}

text_measure_width :: proc(font: ^Text_Font, text: string) -> f32 {
	if font == nil || font.Renderer == nil || len(text) == 0 {
		return 0
	}
	line_width, max_width: f32
	for codepoint in text {
		switch codepoint {
		case '\r':
			continue
		case '\n':
			max_width = max(max_width, line_width)
			line_width = 0
			continue
		}
		resolved := text_resolve_glyph(font, codepoint)
		if !resolved.found {
			continue
		}
		glyph, ok := atlas_manager_get_glyph_metrics(
			font.Renderer.AtlasManager,
			resolved.font_id,
			font.Size64,
			resolved.glyph_id,
		)
		if ok {
			line_width += glyph.advance_x
		}
	}
	return max(max_width, line_width)
}

text_line_height :: #force_inline proc(font: ^Text_Font) -> f32 {
	if font == nil {
		return 0
	}
	return font.Metrics.line_height
}
