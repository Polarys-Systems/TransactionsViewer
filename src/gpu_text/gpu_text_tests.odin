package gpu_text

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
	testing.expect_value(t, y1, i32(5))

	_, _, too_large := pack_glyph(&packer, 11, 1, 10, 10)
	testing.expect(t, !too_large)
}

@(test)
gpu_text_size_quantization :: proc(t: ^testing.T) {
	quantized := atlas_quantize_size_64(12.5)
	testing.expect_value(t, quantized, u32(800))
	testing.expect_value(t, atlas_size_from_quantized_64(quantized), f32(12.5))
}
