package main

import "core:c"
import "core:slice"
import "core:fmt"
import "core:os"
import "core:time"
import "core:math"
import "core:strings"

import vk "vendor:vulkan"

import gpu "gpu"
import gpu_text "gpu_text"
import SDL "vendor:sdl3"

import mui "vendor:microui"

// Profiling
import "base:runtime"
import "core:prof/spall"
import "core:sync"

import "app"

// Global definitions
//
ui_ctx : ^mui.Context;


// --------------------------------------------------------------- //

window_data :: struct {
	screen_width  : f32,
	screen_height : f32,
}

window_pixel_scale :: proc(window: ^SDL.Window) -> [2]f32 {
	if window == nil {
		return {1, 1}
	}

	window_width, window_height: c.int
	pixel_width, pixel_height: c.int
	if !SDL.GetWindowSize(window, &window_width, &window_height) ||
	   !SDL.GetWindowSizeInPixels(window, &pixel_width, &pixel_height) ||
	   window_width <= 0 || window_height <= 0 {
		return {1, 1}
	}

	return {
		f32(pixel_width) / f32(window_width),
		f32(pixel_height) / f32(window_height),
	}
}

// --------------------------------------------------------------- //

spall_ctx: spall.Context
@(thread_local) spall_buffer: spall.Buffer

// Automatic profiling of every procedure:

@(instrumentation_enter)
spall_enter :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
	spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
}

@(instrumentation_exit)
spall_exit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
	spall._buffer_end(&spall_ctx, &spall_buffer)
}

// --------------------------------------------------------------- //

RectVert2D :: struct {
	top_left        : [2]f32,
	bottom_right    : [2]f32,
	color_top       : [4]f32,
	color_bottom    : [4]f32,
	top_left_uv     : [2]f32,
	bottom_right_uv : [2]f32,
	radius          : f32,
	edge            : f32,
}

RectVert2D_set_dim :: proc(self: ^RectVert2D, top_left : [2]f32, size: [2]f32) {
	self.top_left[0] = top_left[0];
	self.top_left[1] = top_left[1];

	self.bottom_right[0] = top_left[0] + size[0];
	self.bottom_right[1] = top_left[1] + size[1];
}

RectVert2D_set_color_top :: proc(self: ^RectVert2D, color: [4]f32) {
	self.color_top[0] = color[0]
	self.color_top[1] = color[1]
	self.color_top[2] = color[2]
	self.color_top[3] = color[3]
}

RectVert2D_set_color_bottom :: proc(self: ^RectVert2D, color: [4]f32) {
	self.color_bottom[0] = color[0]
	self.color_bottom[1] = color[1]
	self.color_bottom[2] = color[2]
	self.color_bottom[3] = color[3]
}

// Increases or decreases the size of the rect
// 
RectVert2D_add_offset :: proc(self: ^RectVert2D, offset: [2]f32) {
	self.bottom_right[0] += offset[0];
	self.bottom_right[1] += offset[1];
}

// Moves the rect top left top_left pixels
//
RectVert2D_move :: proc(self: ^RectVert2D, top_left: [2]f32) {
	self.top_left[0] += top_left[0];
	self.top_left[1] += top_left[1];
}

RectVert2D_create_vertex_attribute :: proc() -> [8]vk.VertexInputAttributeDescription {
	return [?]vk.VertexInputAttributeDescription{
		vk.VertexInputAttributeDescription{
			location = 0, 
			binding  = 0,
			format   = .R32G32_SFLOAT,
			offset   = 0,
		},
		vk.VertexInputAttributeDescription{
			location = 1, 
			binding  = 0,
			format   = .R32G32_SFLOAT,
			offset   = cast(u32)offset_of(RectVert2D, bottom_right),
		},
		vk.VertexInputAttributeDescription{
			location = 2, 
			binding  = 0,
			format   = .R32G32B32A32_SFLOAT,
			offset   = cast(u32)offset_of(RectVert2D, color_top),
		},
		vk.VertexInputAttributeDescription{
			location = 3, 
			binding  = 0,
			format   = .R32G32B32A32_SFLOAT,
			offset   = cast(u32)offset_of(RectVert2D, color_bottom),
		},
		vk.VertexInputAttributeDescription{
			location = 4, 
			binding  = 0,
			format   = .R32G32_SFLOAT,
			offset   = cast(u32)offset_of(RectVert2D, top_left_uv),
		},
		vk.VertexInputAttributeDescription{
			location = 5, 
			binding  = 0,
			format   = .R32G32_SFLOAT,
			offset   = cast(u32)offset_of(RectVert2D, bottom_right_uv),
		},
		vk.VertexInputAttributeDescription{
			location = 6, 
			binding  = 0,
			format   = .R32_SFLOAT,
			offset   = cast(u32)offset_of(RectVert2D, radius),
		},
		vk.VertexInputAttributeDescription{
			location = 7, 
			binding  = 0,
			format   = .R32_SFLOAT,
			offset   = cast(u32)offset_of(RectVert2D, edge),
		},
	}
}

RectVert2D_create_pipeline :: proc(ctx: ^gpu.Gpu_Context) -> gpu.Gpu_Pipeline {
	rect_attr := RectVert2D_create_vertex_attribute()
	rect_descriptor := gpu.gpu_pipeline_desc_default_2d();
	rect_descriptor.VertShaderPath = "../shaders/ui_rect.vert.spv"; 
	rect_descriptor.FragShaderPath = "../shaders/ui_rect.frag.spv"; 
	rect_descriptor.VertShaderCode = #load("../shaders/ui_rect.vert.spv"); 
	rect_descriptor.FragShaderCode = #load("../shaders/ui_rect.frag.spv"); 
	rect_descriptor.VertexAttributes = rect_attr[:]
	rect_descriptor.VertexBindings = []vk.VertexInputBindingDescription {
		vk.VertexInputBindingDescription {
			binding = 0,
			stride  = 18 * size_of(f32),
			inputRate = .INSTANCE
		}
	}
	window_index_range := [1]vk.PushConstantRange{{
		stageFlags = {.VERTEX},
		offset     = 0,
		size       = size_of(window_data),
	}}
	rect_descriptor.PushConstants = window_index_range[:]

	// The descriptor slices reference locals, so Vulkan must consume them before
	// this procedure returns.
	return gpu.gpu_create_graphics_pipeline(ctx, rect_descriptor)
}

// --------------------------------------------------------------- //

UI_Font :: struct {
	renderer: ^gpu_text.Text_Renderer,
	font_id:  u32,
	size:     f32,
}

ui_icon_codepoint :: proc(icon: mui.Icon) -> rune {
	switch icon {
	case .CLOSE:     return rune(0xF00D)
	case .CHECK:     return rune(0xF00C)
	case .COLLAPSED: return rune(0xF0DA)
	case .EXPANDED:  return rune(0xF0D7)
	case .RESIZE:    return rune(0xF065)
	case .NONE:      return 0
	}
	return 0
}

ui_get_text_width :: proc(font : mui.Font, str : string) -> i32 {
	if font == nil {
		return 0
	}
	ui_font := transmute(^UI_Font)font
	width := gpu_text.text_measure_width(ui_font.renderer, str, ui_font.size, ui_font.font_id)
	return i32(math.ceil(width))
}

// --------------------------------------------------------------- //

ui_get_text_height :: proc(font : mui.Font) -> i32 {
	if font == nil {
		return 0
	}
	ui_font := transmute(^UI_Font)font
	height := gpu_text.text_measure_height(ui_font.renderer, ui_font.size, ui_font.font_id)
	return i32(math.ceil(height))
}

main :: proc() {

	// profiling init
	//
	spall_ctx = spall.context_create("trace_test.spall")
	defer spall.context_destroy(&spall_ctx)

	buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
	defer delete(buffer_backing)

	spall_buffer = spall.buffer_create(buffer_backing, u32(sync.current_thread_id()))
	defer spall.buffer_destroy(&spall_ctx, &spall_buffer)

	// vulkan renderer init
	//
	desc := gpu.gpu_desc_default()
	desc.app_name = "Polaris System"
	desc.window.title = desc.app_name
	desc.window.high_pixel_density = true

	ctx, err := gpu.gpu_init(&desc)
	if !gpu.gpu_error_is_ok(err) {
		panic(err.message)
	}
	defer gpu.gpu_shutdown(ctx)

	font_renderer := gpu_text.text_renderer_create(ctx);
	defer gpu_text.destroy_text_renderer(ctx, &font_renderer);

	rect_buffer := gpu.gpu_create_buffer(
		ctx, 
		1 << 20,
		vk.BufferUsageFlags{.VERTEX_BUFFER, .SHADER_DEVICE_ADDRESS, .STORAGE_BUFFER},
		.Auto,
		"buffer rect"
	);
	defer gpu.gpu_destroy_buffer(ctx, &rect_buffer);

	uniform_buffers := [2]gpu.Gpu_Buffer{
		gpu.gpu_create_buffer(ctx, size_of(window_data), {.UNIFORM_BUFFER}),
		gpu.gpu_create_buffer(ctx, size_of(window_data), {.UNIFORM_BUFFER})
	}

	defer gpu.gpu_destroy_buffer(ctx, &uniform_buffers[0])
	defer gpu.gpu_destroy_buffer(ctx, &uniform_buffers[1])

	gpu.gpu_bindless_write_uniform(
		ctx,
		0,
		uniform_buffers[0].buffer,
		0,
		size_of(window_data),
	)
	gpu.gpu_bindless_write_uniform(
		ctx,
		1,
		uniform_buffers[1].buffer,
		0,
		size_of(window_data),
	)

	rect_descriptor := gpu.gpu_pipeline_desc_default_2d();
	rect_descriptor.VertShaderPath = "../shaders/graph_charts.vert.spv"; 
	rect_descriptor.FragShaderPath = "../shaders/graph_charts.frag.spv"; 
	rect_descriptor.VertShaderCode = #load("../shaders/graph_charts.vert.spv"); 
	rect_descriptor.FragShaderCode = #load("../shaders/graph_charts.frag.spv"); 
	rect_descriptor.VertexAttributes = []vk.VertexInputAttributeDescription{
		vk.VertexInputAttributeDescription{
			location = 0, 
			binding  = 0,
			format   = .R32G32_SFLOAT,
			offset   = 0,
		},
		vk.VertexInputAttributeDescription{
			location = 1, 
			binding  = 0,
			format   = .R32G32_SFLOAT,
			offset   = 2 * size_of(f32),
		},
		vk.VertexInputAttributeDescription{
			location = 2, 
			binding  = 0,
			format   = .R32G32B32A32_SFLOAT,
			offset   = 4 * size_of(f32),
		},
	};
	rect_descriptor.VertexBindings = []vk.VertexInputBindingDescription {
		vk.VertexInputBindingDescription {
			binding = 0,
			stride  = 8 * size_of(f32),
			inputRate = .VERTEX
		}
	}
	window_index_range := [1]vk.PushConstantRange{{
		stageFlags = {.VERTEX},
		offset     = 0,
		size       = size_of(u32),
	}}
	rect_descriptor.PushConstants = window_index_range[:]

	rect_pipeline := gpu.gpu_create_graphics_pipeline(ctx, rect_descriptor);
	defer gpu.gpu_destroy_pipeline(ctx, &rect_pipeline);

	// rect 2d pipeline
	rect_2d_pipeline := RectVert2D_create_pipeline(ctx)
	defer gpu.gpu_destroy_pipeline(ctx, &rect_2d_pipeline)

	rect_2d_buffer := [2]gpu.Gpu_Buffer { 
		gpu.gpu_create_buffer(
			ctx, 
			1 << 20,
			vk.BufferUsageFlags{.VERTEX_BUFFER, .SHADER_DEVICE_ADDRESS},
			.Auto,
			"buffer 2d rect"
		),
		gpu.gpu_create_buffer(
			ctx, 
			1 << 20,
			vk.BufferUsageFlags{.VERTEX_BUFFER, .SHADER_DEVICE_ADDRESS},
			.Auto,
			"buffer 2d rect"
		),
	}
	defer gpu.gpu_destroy_buffer(ctx, &rect_2d_buffer[0])
	defer gpu.gpu_destroy_buffer(ctx, &rect_2d_buffer[1])

	// microui init
	// 
	ui_ctx := new(mui.Context)
	mui.init(ui_ctx)
	ui_ctx.text_width  = ui_get_text_width 
	ui_ctx.text_height = ui_get_text_height

	//rect_descriptor := gpu.gpu_bindless_set(ctx);

	roboto_mono_id, ok := gpu_text.text_renderer_register_font(
		&font_renderer,
		"./assets/fonts/RobotoMono.ttf",
		context.temp_allocator
	);
	if !ok {
		fmt.println("[FONT][ERROR] Could not open font");
		return
	}
	ui_font := UI_Font{
		renderer = &font_renderer,
		font_id  = roboto_mono_id,
		size     = 24,
	}
	ui_ctx.style.font = transmute(mui.Font)&ui_font
	ui_ctx.style.size.y = auto_cast ui_font.size

	icons_font_id, ok_icon := gpu_text.text_renderer_register_font(
		&font_renderer,
		"./assets/fonts/SymbolsNerdFontMono-Regular.ttf",
		context.temp_allocator
	);
	if !ok_icon {
		fmt.println("[FONT][ERROR] Could not open font");
		return
	}
	ui_font_icon := UI_Font{
		renderer = &font_renderer,
		font_id  = icons_font_id,
		size     = 24,
	}
	if !gpu_text.text_renderer_set_icon_font(&font_renderer, icons_font_id) {
		fmt.println("[FONT][ERROR] Could not select icon font")
		return
	}
	icon_ids := [5]mui.Icon{.CLOSE, .CHECK, .COLLAPSED, .EXPANDED, .RESIZE}
	for icon in icon_ids {
		_ = gpu_text.text_renderer_prepare_icon(
			&font_renderer,
			ui_icon_codepoint(icon),
			ui_font_icon.size,
		)
	}
	gpu_text.text_renderer_upload(ctx, &font_renderer)

	statoshi_font_id, satoshi_ok := gpu_text.text_renderer_register_font(
	    &font_renderer,
	    "./assets/fonts/Satoshi_Complete/Satoshi_Complete/Fonts/OTF/Satoshi-Regular.otf",
	    context.temp_allocator,
	)
	if !satoshi_ok {
		fmt.println("[FONT][ERROR] Could not load satoshi font")
		return
	}
	satoshi_ui_font := UI_Font{
		renderer = &font_renderer,
		font_id  = statoshi_font_id,
		size     = 18,
	}

	running := true
	smoke_frames := -1
	for arg in os.args {
		if arg == "--gpu-smoke" do smoke_frames = 3
	}

	if !ok {
		fmt.println("[FONT][ERROR] Font not valid or nil argument");
	}

	duration : time.Duration = {};
	start_time := time.tick_now()

	app_context : app.context_t
	app_context.csv_files = make([dynamic]string, 0, 16, context.allocator)
	app_context.csv_documents = make([dynamic]app.CSV_Document, 0, 16, context.allocator)
	defer app.csv_documents_destroy(app_context.csv_documents[:])
	defer delete(app_context.csv_documents)
	defer delete(app_context.csv_files)

	drag_and_drop := false

	for running {

		now := time.tick_now();
		mouse_scale := window_pixel_scale(gpu.gpu_window(ctx))

		event: SDL.Event
		for SDL.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				running = false
			case .MOUSE_MOTION:
				mui.input_mouse_move(
					ui_ctx,
					i32(event.motion.x * mouse_scale[0]),
					i32(event.motion.y * mouse_scale[1]),
				)
			case .TEXT_INPUT:
				text_input, _ := strings.clone_from_cstring(event.text.text, context.temp_allocator)
				if len(text_input) > 0 {
					mui.input_text(ui_ctx, string(text_input[:len(text_input)]))
				}
			case .MOUSE_BUTTON_DOWN:
				mui.input_mouse_down(
					ui_ctx,
					i32(event.button.x * mouse_scale[0]),
					i32(event.button.y * mouse_scale[1]),
					.LEFT,
				)
			case .MOUSE_BUTTON_UP:
				mui.input_mouse_up(
					ui_ctx,
					i32(event.button.x * mouse_scale[0]),
					i32(event.button.y * mouse_scale[1]),
					.LEFT,
				)
			case .DROP_BEGIN:
		        // A drag entered / drop sequence began.
		        SDL.Log("Drop begin\n")
		        drag_and_drop = true 
		    case .DROP_POSITION:
		        // event.drop.x and event.drop.y are the current pointer position.
		        //show_drop_highlight(event.drop.x, event.drop.y);
			case .DROP_FILE:
		        SDL.Log("Dropped file: %s", event.drop.data);

		        //app.iterate_csv_from_stream(strings.clone_from_cstring(event.drop.data))
		        append(&app_context.csv_files, strings.clone_from_cstring(event.drop.data))
		        // Load or queue the file here.
		        // load_file(event.drop.data);

		        //SDL.free(rawptr(event.drop.data)); // SDL allocates this string
		    case .DROP_COMPLETE:
		    	drag_and_drop = false 
		        // Drag ended, whether or not a file was dropped.
		        //hide_drop_highlight();
			case:
			}
		}
		if !running {
			break
		}

		mui.begin(ui_ctx)
		if mui.begin_window(ui_ctx, "Hello Window", mui.Rect{100, 100, 400, 400}) {
			win_size := mui.get_layout(ui_ctx).size;
			pad := mui.get_layout(ui_ctx).indent;
			mui.layout_row(ui_ctx, []i32{win_size.x - ui_ctx.style.padding / 2}, mui.get_layout(ui_ctx).size.y)
			mui.label(ui_ctx, "This is a label")
			mui.layout_row(ui_ctx, []i32{win_size.x - ui_ctx.style.padding / 2}, mui.get_layout(ui_ctx).size.y)
			mui.button(ui_ctx, "This is a button", .NONE, {})
			mui.end_window(ui_ctx)
		}

		if drag_and_drop {
			screen_w, screen_h := ctx.base.Window.last_extent.width, ctx.base.Window.last_extent.height
			if mui.begin_window(ui_ctx, "Drag and Drop", mui.Rect{cast(i32)20, cast(i32)20, cast(i32)screen_w - 40, cast(i32)screen_h - 40}) {
				win_size := mui.get_layout(ui_ctx).size;
				pad := mui.get_layout(ui_ctx).indent;
				mui.layout_row(ui_ctx, []i32{win_size.x - ui_ctx.style.padding / 2}, win_size.y- ui_ctx.style.padding / 2)
				mui.end_window(ui_ctx)
			}
		}

		if len(app_context.csv_files) > 0 {
			if mui.begin_window(ui_ctx, "Files", mui.Rect{40, 40, 400, 240}) {
				mui.layout_row(ui_ctx, []i32{270, 110}, 0)
				for filename, file_index in app_context.csv_files {
					mui.label(ui_ctx, filename)
					mui.push_id_uintptr(ui_ctx, uintptr(file_index))
					button_label := "Not Processed"
					if app.csv_document_exists(app_context.csv_documents[:], filename) {
						button_label = "Processed"
					}
					if .SUBMIT in mui.button(ui_ctx, button_label) && button_label == "Not Processed" {
						append(&app_context.csv_documents, app.csv_document_read(filename))
					}
					mui.pop_id(ui_ctx)
				}
				mui.end_window(ui_ctx)
			}
		}

		for document, document_index in app_context.csv_documents {
			offset := i32(document_index % 3) * 24
			window_rect := mui.Rect{280 + offset, 80 + offset, 720, 440}
			if mui.begin_window(ui_ctx, document.path, window_rect) {
				layout := mui.get_layout(ui_ctx)
				n_cols := document.column_count
				if n_cols > 0 {
					rows : []i32 = make_slice([]i32, n_cols, context.temp_allocator)
					column_width := layout.body.w / auto_cast n_cols
					for i in 0..<n_cols {
						rows[i] = column_width
					}
					for row in document.rows {
						// Height 0 lets microui use its normal control height.
						mui.layout_row(ui_ctx, rows, 0)
						for val in row {
							mui.label(ui_ctx, val)
						}
					}
				}
				mui.end_window(ui_ctx)
			}
		}

		mui.end(ui_ctx)

		frame, frame_err := gpu.gpu_begin_frame(ctx)
		if !gpu.gpu_error_is_ok(frame_err) {
			continue
		}

		gpu.gpu_begin_swapchain_rendering(ctx, frame, {
			clear = true,
			color = {0.02, 0.025, 0.04, 1.0},
		})

		screen := window_data {
			screen_width  = cast(f32)frame.extent.width,
			screen_height = cast(f32)frame.extent.height
		}

		elapsed := cast(f32)time.duration_milliseconds(time.tick_since(start_time)) / 1000.0
		viewport := vk.Viewport{
			x        = 0,
			y        = 0,
			width    = f32(frame.extent.width),
			height   = f32(frame.extent.height),
			minDepth = 0,
			maxDepth = 1,
		}
		current_scissor := vk.Rect2D{
			offset = {0, 0},
			extent = frame.extent,
		}
		vk.CmdSetViewport(frame.cmd, 0, 1, &viewport)
		vk.CmdSetScissor(frame.cmd, 0, 1, &current_scissor)
		rect_buffer_offset: u64 = 0

		{
			current_command: ^mui.Command
			for variant in mui.next_command_iterator(ui_ctx, &current_command) {
				switch cmd in variant {
				case ^mui.Command_Text:
					pos := [2]i32{cmd.pos.x, cmd.pos.y}
					_font := cast(^UI_Font)cmd.font
					font_id := _font.font_id;
					color : [4]f32 = {
						cast(f32)cmd.color.r / 255,
						cast(f32)cmd.color.g / 255,
						cast(f32)cmd.color.b / 255,
						cast(f32)cmd.color.a / 255
					}
					ok = gpu_text.text_renderer_prepare(
						&font_renderer,
						cmd.str,
						_font.size,
						font_id
					);
					gpu_text.text_renderer_upload(ctx, &font_renderer)
					baseline_y := f32(cmd.pos.y) + gpu_text.text_baseline_offset_for_font(
					    &font_renderer,
					    font_id,
					    _font.size,
					)
					gpu_text.draw_text_colored_font(
						ctx,
						&font_renderer,
						frame.cmd,
						cmd.str,
						cast(f32)pos.x, baseline_y,
						_font.size,
						font_id,
						color,
						current_scissor,
						frame.extent
					);
				case ^mui.Command_Rect:
					color : [4]f32 = {
						cast(f32)cmd.color.r / 255,
						cast(f32)cmd.color.g / 255,
						cast(f32)cmd.color.b / 255,
						cast(f32)cmd.color.a / 255
					}
					rect := RectVert2D {
						top_left = {cast(f32)cmd.rect.x, cast(f32)cmd.rect.y},
						bottom_right = {cast(f32)cmd.rect.x + cast(f32)cmd.rect.w, cast(f32)cmd.rect.y + cast(f32)cmd.rect.h},
						color_top = color,
						color_bottom = {color.r - 0.02, color.g - 0.02, color.b - 0.02, color.a},
						radius = 8,
						edge   = 0,
					} 
					gpu.gpu_upload_buffer(ctx, &rect_2d_buffer[frame.frame_slot], &rect, size_of(RectVert2D), rect_buffer_offset);
					gpu.gpu_bind_pipeline(ctx, frame.cmd, &rect_2d_pipeline);
					gpu.gpu_push_constants(ctx, frame.cmd, &rect_2d_pipeline, {.VERTEX}, &screen, size_of(window_data), 0)
					offset := vk.DeviceSize(rect_buffer_offset)
					vk.CmdBindVertexBuffers(frame.cmd, 0, 1, &rect_2d_buffer[frame.frame_slot].buffer, &offset)
					vk.CmdDraw(frame.cmd, 6, 1, 0, 0);
					rect_buffer_offset += size_of(RectVert2D)

				case ^mui.Command_Icon:
					codepoint := ui_icon_codepoint(cmd.id)
					if codepoint != 0 {
						color := [4]f32{
							f32(cmd.color.r) / 255,
							f32(cmd.color.g) / 255,
							f32(cmd.color.b) / 255,
							f32(cmd.color.a) / 255,
						}
						gpu_text.draw_icon_codepoint(
							ctx,
							&font_renderer,
							frame.cmd,
							codepoint,
							f32(cmd.rect.x),
							f32(cmd.rect.y),
							f32(cmd.rect.w),
							f32(cmd.rect.h),
							ui_font_icon.size,
							color,
							current_scissor,
							frame.extent,
						)
					}
				case ^mui.Command_Clip:
					frame_w := i32(frame.extent.width)
					frame_h := i32(frame.extent.height)
					x0 := clamp(cmd.rect.x, 0, frame_w)
					y0 := clamp(cmd.rect.y, 0, frame_h)
					x1 := clamp(cmd.rect.x + cmd.rect.w, x0, frame_w)
					y1 := clamp(cmd.rect.y + cmd.rect.h, y0, frame_h)
					current_scissor = {
						offset = {x0, y0},
						extent = {u32(x1 - x0), u32(y1 - y0)},
					}
					vk.CmdSetScissor(frame.cmd, 0, 1, &current_scissor)
				case ^mui.Command_Jump: 
					unreachable()
				}
			}
		}

		gpu.gpu_end_swapchain_rendering(ctx, frame)
		_ = gpu.gpu_end_frame(ctx, frame)
		if smoke_frames > 0 {
			smoke_frames -= 1
			if smoke_frames == 0 do running = false
		}

		free_all(context.temp_allocator)

		duration = time.tick_since(now)
	}

	fmt.println("Exited.")
}
