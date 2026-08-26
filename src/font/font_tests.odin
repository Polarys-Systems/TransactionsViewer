package font

import "core:os"
import "core:testing"

test_stb_face :: proc(t: ^testing.T, path: string) {
	data, read_error := os.read_entire_file(path, context.allocator)
	testing.expect(t, read_error == nil)
	if read_error != nil {
		return
	}
	defer delete(data)

	face, loaded := face_load_from_data(0, data)
	testing.expect(t, loaded)
	if !loaded {
		return
	}
	defer face_destroy(&face)
	testing.expect(t, face.stb_valid)
	if !face.stb_valid {
		return
	}
	face.backend = .STB

	glyph, found := glyph_index(&face, 'A')
	testing.expect(t, found)
	if !found {
		return
	}
	advance, measured := glyph_advance(&face, glyph, 12 * 64)
	testing.expect(t, measured)
	testing.expect(t, advance > 0)
	metrics := line_metrics(&face, 12 * 64)
	testing.expect(t, metrics.line_height > 0)
	bitmap, rasterized := rasterize_glyph(&face, 12 * 64, glyph)
	testing.expect(t, rasterized)
	testing.expect(t, bitmap.width > 0 && bitmap.height > 0)
}

@(test)
font_stb_supports_shipped_formats :: proc(t: ^testing.T) {
	test_stb_face(t, "./assets/fonts/RobotoMono.ttf")
	test_stb_face(t, "./assets/fonts/Satoshi_Complete/Satoshi_Complete/Fonts/OTF/Satoshi-Regular.otf")
}
