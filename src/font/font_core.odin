package font

import "core:c"
import stbtt "vendor:stb/truetype"

when ODIN_OS == .Linux {
	@(extra_linker_flags="-lfreetype")
	foreign import freetype "system:freetype"
}

FT_Byte :: c.uchar
FT_Short :: c.short
FT_UShort :: c.ushort
FT_Int :: c.int
FT_UInt :: c.uint
FT_Long :: c.long
FT_Fixed :: c.long
FT_Pos :: c.long
FT_F26Dot6 :: c.long
FT_Error :: c.int
FT_Int32 :: i32

FT_Library :: distinct rawptr
FT_Face :: ^FT_FaceRec
FT_Size :: ^FT_SizeRec
FT_GlyphSlot :: ^FT_GlyphSlotRec
FT_CharMap :: rawptr
FT_Driver :: rawptr
FT_Memory :: rawptr
FT_Stream :: rawptr
FT_SubGlyph :: rawptr

FT_Vector :: struct {
	x, y: FT_Pos,
}

FT_BBox :: struct {
	xMin, yMin, xMax, yMax: FT_Pos,
}

FT_Generic_Finalizer :: proc "c" (object: rawptr)

FT_Generic :: struct {
	data: rawptr,
	finalizer: FT_Generic_Finalizer,
}

FT_Bitmap_Size :: struct {
	height: FT_Short,
	width:  FT_Short,
	size:   FT_Pos,
	x_ppem: FT_Pos,
	y_ppem: FT_Pos,
}

FT_Size_Metrics :: struct {
	x_ppem: FT_UShort,
	y_ppem: FT_UShort,
	x_scale: FT_Fixed,
	y_scale: FT_Fixed,
	ascender: FT_Pos,
	descender: FT_Pos,
	height: FT_Pos,
	max_advance: FT_Pos,
}

FT_SizeRec :: struct {
	face: FT_Face,
	generic: FT_Generic,
	metrics: FT_Size_Metrics,
	internal: rawptr,
}

FT_Glyph_Metrics :: struct {
	width: FT_Pos,
	height: FT_Pos,
	horiBearingX: FT_Pos,
	horiBearingY: FT_Pos,
	horiAdvance: FT_Pos,
	vertBearingX: FT_Pos,
	vertBearingY: FT_Pos,
	vertAdvance: FT_Pos,
}

FT_Bitmap :: struct {
	rows: c.uint,
	width: c.uint,
	pitch: c.int,
	buffer: ^FT_Byte,
	num_grays: c.ushort,
	pixel_mode: c.uchar,
	palette_mode: c.uchar,
	palette: rawptr,
}

FT_Outline :: struct {
	n_contours: c.ushort,
	n_points: c.ushort,
	points: ^FT_Vector,
	tags: ^c.uchar,
	contours: ^c.ushort,
	flags: c.int,
}

FT_GlyphSlotRec :: struct {
	library: FT_Library,
	face: FT_Face,
	next: FT_GlyphSlot,
	glyph_index: FT_UInt,
	generic: FT_Generic,
	metrics: FT_Glyph_Metrics,
	linearHoriAdvance: FT_Fixed,
	linearVertAdvance: FT_Fixed,
	advance: FT_Vector,
	format: c.uint,
	bitmap: FT_Bitmap,
	bitmap_left: FT_Int,
	bitmap_top: FT_Int,
	outline: FT_Outline,
	num_subglyphs: FT_UInt,
	subglyphs: FT_SubGlyph,
	control_data: rawptr,
	control_len: c.long,
}

FT_ListRec :: struct {
	head: rawptr,
	tail: rawptr,
}

FT_FaceRec :: struct {
	num_faces: FT_Long,
	face_index: FT_Long,
	face_flags: FT_Long,
	style_flags: FT_Long,
	num_glyphs: FT_Long,
	family_name: cstring,
	style_name: cstring,
	num_fixed_sizes: FT_Int,
	available_sizes: ^FT_Bitmap_Size,
	num_charmaps: FT_Int,
	charmaps: ^FT_CharMap,
	generic: FT_Generic,
	bbox: FT_BBox,
	units_per_EM: FT_UShort,
	ascender: FT_Short,
	descender: FT_Short,
	height: FT_Short,
	max_advance_width: FT_Short,
	max_advance_height: FT_Short,
	underline_position: FT_Short,
	underline_thickness: FT_Short,
	glyph: FT_GlyphSlot,
	size: FT_Size,
	charmap: FT_CharMap,
	driver: FT_Driver,
	memory: FT_Memory,
	stream: FT_Stream,
	sizes_list: FT_ListRec,
	autohint: FT_Generic,
	extensions: rawptr,
}

FT_LOAD_DEFAULT :: FT_Int32(0)
FT_LOAD_RENDER :: FT_Int32(1 << 2)
FT_RENDER_MODE_NORMAL :: c.int(0)
FT_PIXEL_MODE_GRAY :: c.uchar(2)
ft_library_nil :: FT_Library(uintptr(0))

when ODIN_OS == .Linux {
	@(default_calling_convention = "c", link_prefix = "FT_")
	foreign freetype {
		Init_FreeType :: proc(alibrary: ^FT_Library) -> FT_Error ---
		Done_FreeType :: proc(library: FT_Library) -> FT_Error ---
		New_Memory_Face :: proc(library: FT_Library, file_base: ^FT_Byte, file_size: FT_Long, face_index: FT_Long, aface: ^FT_Face) -> FT_Error ---
		Done_Face :: proc(face: FT_Face) -> FT_Error ---
		Set_Char_Size :: proc(face: FT_Face, char_width, char_height: FT_F26Dot6, horizontal_resolution, vertical_resolution: FT_UInt) -> FT_Error ---
		Load_Glyph :: proc(face: FT_Face, glyph_index: FT_UInt, load_flags: FT_Int32) -> FT_Error ---
		Get_Char_Index :: proc(face: FT_Face, charcode: c.ulong) -> FT_UInt ---
	}
}

Backend :: enum {
	STB,
	FreeType,
}

Face :: struct {
	id: u32,
	path: string,
	data: []byte,
	backend: Backend,
	stb_info: stbtt.fontinfo,
	stb_valid: bool,
	ft_face: FT_Face,
	ft_valid: bool,
	ft_size_64: u32,
}

Line_Metrics :: struct {
	ascent: f32,
	descent: f32,
	line_gap: f32,
	line_height: f32,
}

Glyph_Bitmap :: struct {
	pixels: []byte,
	width: i32,
	height: i32,
	xoff: f32,
	yoff: f32,
	xoff2: f32,
	yoff2: f32,
	advance_x: f32,
	advance_y: f32,
}

library: FT_Library
library_initialized: bool
library_available: bool

init_once :: proc() -> bool {
	when ODIN_OS == .Linux {
		if library_initialized {
			return library_available
		}
		library_initialized = true
		err := Init_FreeType(&library)
		library_available = err == 0 && library != ft_library_nil
		return library_available
	} else {
		return false
	}
}

shutdown :: proc() {
	when ODIN_OS == .Linux {
		if library_available && library != ft_library_nil {
			_ = Done_FreeType(library)
		}
		library = ft_library_nil
		library_initialized = false
		library_available = false
	}
}

size_from_64 :: #force_inline proc(size_64: u32) -> f32 {
	return max(f32(size_64) / 64.0, 1.0 / 64.0)
}

face_load_from_data :: proc(id: u32, font_data: []byte, path: string = "", allocator := context.allocator) -> (Face, bool) {
	if len(font_data) == 0 {
		return {}, false
	}

	face := Face{id = id, path = path}
	face.data = make([]byte, len(font_data), allocator)
	copy(face.data, font_data)
	face.stb_valid = bool(stbtt.InitFont(&face.stb_info, raw_data(face.data), 0))

	when ODIN_OS == .Linux {
		if init_once() {
			ft_face: FT_Face
			err := New_Memory_Face(
				library,
				transmute(^FT_Byte)raw_data(face.data),
				FT_Long(len(face.data)),
				0,
				&ft_face,
			)
			if err == 0 && ft_face != nil {
				face.ft_face = ft_face
				face.ft_valid = true
				face.backend = .FreeType
			}
		}
	}

	if !face.ft_valid && face.stb_valid {
		face.backend = .STB
	}
	if !face.ft_valid && !face.stb_valid {
		delete(face.data, allocator)
		return {}, false
	}
	return face, true
}

face_destroy :: proc(face: ^Face, allocator := context.allocator) {
	if face == nil {
		return
	}
	when ODIN_OS == .Linux {
		if face.ft_valid && face.ft_face != nil {
			_ = Done_Face(face.ft_face)
		}
	}
	if face.data != nil {
		delete(face.data, allocator)
	}
	face^ = {}
}

face_set_size :: proc(face: ^Face, size_64: u32) -> bool {
	when ODIN_OS == .Linux {
		if face == nil || face.backend != .FreeType || !face.ft_valid || face.ft_face == nil {
			return false
		}
		if face.ft_size_64 == size_64 {
			return true
		}
		if Set_Char_Size(face.ft_face, 0, FT_F26Dot6(max(size_64, 1)), 72, 72) != 0 {
			return false
		}
		face.ft_size_64 = size_64
		return true
	} else {
		return false
	}
}

glyph_index :: proc(face: ^Face, r: rune) -> (i32, bool) {
	if face == nil {
		return 0, false
	}
	when ODIN_OS == .Linux {
		if face.backend == .FreeType && face.ft_valid && face.ft_face != nil {
			idx := Get_Char_Index(face.ft_face, c.ulong(r))
			return i32(idx), idx > 0
		}
	}
	if face.backend == .STB && face.stb_valid {
		idx := stbtt.FindGlyphIndex(&face.stb_info, r)
		return idx, idx > 0
	}
	return 0, false
}

glyph_advance :: proc(face: ^Face, glyph_idx: i32, size_64: u32) -> (f32, bool) {
	if face == nil || glyph_idx <= 0 {
		return 0, false
	}
	when ODIN_OS == .Linux {
		if face.backend == .FreeType {
			if face_set_size(face, size_64) &&
			   Load_Glyph(face.ft_face, FT_UInt(glyph_idx), FT_LOAD_DEFAULT) == 0 &&
			   face.ft_face.glyph != nil {
				return f32(face.ft_face.glyph.advance.x) / 64.0, true
			}
			return 0, false
		}
	}
	if face.backend == .STB && face.stb_valid {
		scale := stbtt.ScaleForMappingEmToPixels(&face.stb_info, size_from_64(size_64))
		advance_width, left_side_bearing: c.int
		stbtt.GetGlyphHMetrics(&face.stb_info, glyph_idx, &advance_width, &left_side_bearing)
		return f32(advance_width) * scale, true
	}
	return 0, false
}

line_metrics :: proc(face: ^Face, size_64: u32) -> Line_Metrics {
	size_px := size_from_64(size_64)
	when ODIN_OS == .Linux {
		if face != nil && face.backend == .FreeType && face_set_size(face, size_64) && face.ft_face.size != nil {
			m := face.ft_face.size.metrics
			ascent := f32(m.ascender) / 64.0
			descent := f32(m.descender) / 64.0
			height := f32(m.height) / 64.0
			return Line_Metrics{
				ascent = ascent,
				descent = descent,
				line_gap = max(0.0, height - (ascent - descent)),
				line_height = max(1.0, height),
			}
		}
	}
	if face != nil && face.backend == .STB && face.stb_valid {
		scale := stbtt.ScaleForMappingEmToPixels(&face.stb_info, size_px)
		ascent, descent, line_gap: c.int
		stbtt.GetFontVMetrics(&face.stb_info, &ascent, &descent, &line_gap)
		return Line_Metrics{
			ascent = f32(ascent) * scale,
			descent = f32(descent) * scale,
			line_gap = f32(line_gap) * scale,
			line_height = max(1.0, f32(ascent-descent+line_gap) * scale),
		}
	}
	return Line_Metrics{
		ascent = size_px * 0.80,
		descent = -size_px * 0.20,
		line_height = max(1.0, size_px),
	}
}

rasterize_glyph :: proc(face: ^Face, size_64: u32, glyph_idx: i32, allocator := context.temp_allocator) -> (Glyph_Bitmap, bool) {
	if face == nil || glyph_idx <= 0 {
		return {}, false
	}
	when ODIN_OS == .Linux {
		if face.backend == .FreeType {
			if !face_set_size(face, size_64) ||
			   Load_Glyph(face.ft_face, FT_UInt(glyph_idx), FT_LOAD_RENDER) != 0 ||
			   face.ft_face.glyph == nil {
				return {}, false
			}

			slot := face.ft_face.glyph
			advance_x := f32(slot.advance.x) / 64.0
			advance_y := f32(slot.advance.y) / 64.0
			bitmap := slot.bitmap
			w := i32(bitmap.width)
			h := i32(bitmap.rows)
			if w <= 0 || h <= 0 || bitmap.buffer == nil {
				return Glyph_Bitmap{advance_x = advance_x, advance_y = advance_y}, true
			}
			if bitmap.pixel_mode != FT_PIXEL_MODE_GRAY || abs(i32(bitmap.pitch)) < w {
				return {}, false
			}

			pixels := make([]byte, int(w*h), allocator)
			pitch := int(abs(i32(bitmap.pitch)))
			for row := 0; row < int(h); row += 1 {
				src_row := row
				if bitmap.pitch < 0 {
					src_row = int(h) - 1 - row
				}
				src_start := src_row * pitch
				dst_start := row * int(w)
				src := ([^]byte)(bitmap.buffer)[src_start:src_start+int(w)]
				copy(pixels[dst_start:dst_start+int(w)], src)
			}

			xoff := f32(slot.bitmap_left)
			yoff := -f32(slot.bitmap_top)
			return Glyph_Bitmap{
				pixels = pixels,
				width = w,
				height = h,
				xoff = xoff,
				yoff = yoff,
				xoff2 = xoff + f32(w),
				yoff2 = yoff + f32(h),
				advance_x = advance_x,
				advance_y = advance_y,
			}, true
		}
	}

	if face.backend == .STB && face.stb_valid {
		scale := stbtt.ScaleForMappingEmToPixels(&face.stb_info, size_from_64(size_64))
		advance_width, left_side_bearing: c.int
		stbtt.GetGlyphHMetrics(&face.stb_info, glyph_idx, &advance_width, &left_side_bearing)
		advance_x := f32(advance_width) * scale
		ix0, iy0, ix1, iy1: c.int
		stbtt.GetGlyphBitmapBox(&face.stb_info, glyph_idx, scale, scale, &ix0, &iy0, &ix1, &iy1)
		w := ix1 - ix0
		h := iy1 - iy0
		if w <= 0 || h <= 0 {
			return Glyph_Bitmap{advance_x = advance_x}, true
		}
		pixels := make([]byte, int(w*h), allocator)
		stbtt.MakeGlyphBitmap(&face.stb_info, raw_data(pixels), w, h, w, scale, scale, glyph_idx)
		return Glyph_Bitmap{
			pixels = pixels,
			width = i32(w),
			height = i32(h),
			xoff = f32(ix0),
			yoff = f32(iy0),
			xoff2 = f32(ix1),
			yoff2 = f32(iy1),
			advance_x = advance_x,
		}, true
	}
	return {}, false
}
