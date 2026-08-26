package gpu_text

import "core:os"
import "core:testing"

@(test)
gpu_text_shelf_packing :: proc(t: ^testing.T) {
	packer: Shelf_Packer
	x0, y0, ok0 := pack_glyph(&packer, 6, 4, 10, 10)
	testing.expect(t, ok0)
	testing.expect_value(t, x0, i32(0))
	testing.expect_value(t, y0, i32(0))

	x1, y1, ok1 := pack_glyph(&packer, 5, 3, 10, 10)
	testing.expect(t, ok1)
	testing.expect_value(t, x1, i32(0))
	testing.expect_value(t, y1, i32(4))

	before_failure := packer
	_, _, too_large := pack_glyph(&packer, 11, 1, 10, 10)
	testing.expect(t, !too_large)
	testing.expect_value(t, packer, before_failure)
}

@(test)
gpu_text_size_quantization :: proc(t: ^testing.T) {
	quantized := atlas_quantize_size_64(12.5)
	testing.expect_value(t, quantized, u32(800))
	testing.expect_value(t, atlas_size_from_quantized_64(quantized), f32(12.5))
}

@(test)
gpu_text_metrics_are_cached :: proc(t: ^testing.T) {
	renderer := text_renderer_create(nil)
	defer text_renderer_destroy(&renderer)

	font_data, font_error := os.read_entire_file("./assets/fonts/RobotoMono.ttf", context.allocator)
	testing.expect(t, font_error == nil)
	if font_error != nil {
		return
	}
	defer delete(font_data)
	font_id, registered := text_renderer_register_font_data(&renderer, font_data)
	testing.expect(t, registered)
	if !registered {
		return
	}

	font, created := text_font_create(&renderer, font_id, 12.5)
	testing.expect(t, created)
	if !created {
		return
	}
	width := text_measure_width(&font, "Transaction 123")
	testing.expect(t, width > 0)
	glyph_count := len(renderer.AtlasManager.glyphs)
	total_width: f32
	for _ in 0..<10_000 {
		total_width += text_measure_width(&font, "Transaction 123")
	}
	testing.expect(t, total_width > width)
	testing.expect_value(t, len(renderer.AtlasManager.glyphs), glyph_count)
	testing.expect_value(t, len(renderer.AtlasManager.pages), 0)
	testing.expect(t, text_line_height(&font) > 0)

	icon_data, icon_error := os.read_entire_file("./assets/fonts/SymbolsNerdFontMono-Regular.ttf", context.allocator)
	testing.expect(t, icon_error == nil)
	if icon_error != nil {
		return
	}
	defer delete(icon_data)
	icon_id, icon_registered := text_renderer_register_font_data(&renderer, icon_data)
	testing.expect(t, icon_registered)
	if !icon_registered {
		return
	}
	text_renderer_set_fallback_fonts(&renderer, []u32{icon_id})
	resolved := text_resolve_glyph(&font, rune(0xF00D))
	testing.expect(t, resolved.found)
	testing.expect_value(t, resolved.font_id, icon_id)

	font_24, font_24_created := text_font_create(&renderer, font_id, 24)
	testing.expect(t, font_24_created)
	if font_24_created {
		before_other_size := len(renderer.AtlasManager.glyphs)
		testing.expect(t, text_measure_width(&font_24, "Transaction 123") > 0)
		testing.expect(t, len(renderer.AtlasManager.glyphs) > before_other_size)
	}
	icon_font, icon_font_created := text_font_create(&renderer, icon_id, 24)
	testing.expect(t, icon_font_created)
	if icon_font_created {
		before_other_font := len(renderer.AtlasManager.glyphs)
		icon_resolved := text_resolve_glyph(&icon_font, rune(0xF00D))
		testing.expect(t, icon_resolved.found)
		_, icon_metrics_ok := atlas_manager_get_glyph_metrics(
			renderer.AtlasManager,
			icon_resolved.font_id,
			icon_font.Size64,
			icon_resolved.glyph_id,
		)
		testing.expect(t, icon_metrics_ok)
		testing.expect(t, len(renderer.AtlasManager.glyphs) > before_other_font)
	}
}
