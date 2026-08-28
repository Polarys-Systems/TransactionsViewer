package main

import "core:c"
import "core:slice"
import "core:strconv"
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

import "app"

// Global definitions
//
ui_ctx : ^mui.Context;


// --------------------------------------------------------------- //

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
	ui_font := transmute(^gpu_text.Text_Font)font
	width := gpu_text.text_measure_width(ui_font, str)
	return i32(math.ceil(width))
}

// --------------------------------------------------------------- //

ui_get_text_height :: proc(font : mui.Font) -> i32 {
	if font == nil {
		return 0
	}
	ui_font := transmute(^gpu_text.Text_Font)font
	height := gpu_text.text_line_height(ui_font)
	return i32(math.ceil(height))
}

main :: proc() {
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
	defer gpu_text.text_renderer_destroy(&font_renderer);
	ui_renderer := app.ui_renderer_create(ctx)
	defer app.ui_renderer_destroy(ctx, &ui_renderer)

	// microui init
	// 
	ui_ctx := new(mui.Context)
	mui.init(ui_ctx)
	ui_ctx.text_width  = ui_get_text_width 
	ui_ctx.text_height = ui_get_text_height

	roboto_mono_id, ok := gpu_text.text_renderer_register_font(
		&font_renderer,
		"./assets/fonts/RobotoMono.ttf",
		context.temp_allocator
	);
	if !ok {
		fmt.println("[FONT][ERROR] Could not open font");
		return
	}
	ui_font, ui_font_ok := gpu_text.text_font_create(&font_renderer, roboto_mono_id, 18)
	if !ui_font_ok {
		fmt.println("[FONT][ERROR] Could not create UI font size")
		return
	}
	ui_ctx.style.font = transmute(mui.Font)&ui_font
	ui_ctx.style.size.y = auto_cast ui_font.Size

	icons_font_id, ok_icon := gpu_text.text_renderer_register_font(
		&font_renderer,
		"./assets/fonts/SymbolsNerdFontMono-Regular.ttf",
		context.temp_allocator
	);
	if !ok_icon {
		fmt.println("[FONT][ERROR] Could not open font");
		return
	}
	ui_font_icon, icon_font_ok := gpu_text.text_font_create(&font_renderer, icons_font_id, 18)
	if !icon_font_ok {
		fmt.println("[FONT][ERROR] Could not create icon font size")
		return
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

	// graph rendering
	//
	graph_renderer : app.GraphChartState
	app.ui_graph_charts_init(&graph_renderer, ctx)
	defer app.ui_graph_charts_destroy(&graph_renderer)

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
			case .MOUSE_WHEEL:
			    mui.input_scroll(
			        ui_ctx,
			        i32(event.wheel.integer_x) * 40,
			        -i32(event.wheel.integer_y) * 40,
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
		if mui.begin_window(ui_ctx, "Debug Info", mui.Rect{100, 100, 400, 400}) {
			win_size := mui.get_layout(ui_ctx).size;
			pad := mui.get_layout(ui_ctx).indent;
			mui.layout_row(ui_ctx, []i32{win_size.x - ui_ctx.style.padding / 2}, mui.get_layout(ui_ctx).size.y)

			builder : strings.Builder
			strings.builder_init(&builder, context.temp_allocator)
			defer strings.builder_destroy(&builder)
			strings.write_f64(&builder, time.duration_milliseconds(duration), 'f')
			mui.label(ui_ctx, strings.to_string(builder))
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
				win_size := mui.get_layout(ui_ctx).size;
				mui.layout_row(ui_ctx, []i32{win_size.x - 220, 220}, 0)
				for filename, file_index in app_context.csv_files {
					stripped_file_name, err := strings.split_after(filename, "/", context.temp_allocator)
					file_local : string 
					if err != .None {
						file_local = filename
					} else {
						file_local = stripped_file_name[len(stripped_file_name) - 1]
					}
					mui.label(ui_ctx, file_local)
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
			// Call before begin_window, while the ID stack is empty.
			window := mui.get_container(ui_ctx, document.path)

			if mui.begin_window(ui_ctx, document.path, window_rect) {
			    layout := mui.get_layout(ui_ctx)

			    row_h := ui_ctx.style.size.y + 2 * ui_ctx.style.padding
			    row_pitch := row_h + ui_ctx.style.spacing
			    column_w := layout.body.w / i32(document.column_count)

			    first := max(0, window.scroll.y / row_pitch)
			    last := min(
			        cast(i32)len(document.rows),
			        (window.scroll.y + layout.body.h) / row_pitch + 2,
			    )

			    for row_index in first..<last {
			        y := i32(row_index) * row_pitch
		            
		            if cast(int)row_index == app_context.highlighted_row {
		            	mui.draw_rect(ui_ctx, mui.Rect{x = layout.body.x, y = layout.body.y + y, w = layout.body.w, h = row_pitch}, mui.Color{80, 22, 22, 255})
		            } else if row_index % 2 == 0 {
		            	mui.draw_rect(ui_ctx, mui.Rect{x = layout.body.x, y = layout.body.y + y, w = layout.body.w, h = row_pitch}, mui.Color{22, 22, 22, 255})
		            }
			        for value, column_index in document.rows[row_index] {
			            x := i32(column_index) * column_w
			            mui.layout_set_next(ui_ctx, mui.Rect{x, y, column_w, row_h}, true)
			            mui.label(ui_ctx, value)
			        }
			    }

			    // Preserve the full virtual content size for Microui's scrollbar.
			    if len(document.rows) > 0 {
			        y := i32(len(document.rows) - 1) * row_pitch
			        mui.layout_set_next(
			            ui_ctx,
			            mui.Rect{0, y, column_w * i32(document.column_count), row_h},
			            true,
			        )
			        mui.label(ui_ctx, "")
			    }

			    mui.end_window(ui_ctx)
			}
		}

		mui.end(ui_ctx)


		graph_data_global := make([dynamic]f32, context.temp_allocator)
		for document, document_index in app_context.csv_documents {
			graph_data := make([]f32, len(document.rows), context.temp_allocator)
			for row_idx in 0..<len(document.rows) {
				val := document.rows[row_idx][len(document.rows[row_idx]) - 1]
				val_num, _:= strconv.parse_f32(val)
				graph_data[row_idx] = val_num
			}

			append_elems(&graph_data_global, ..graph_data[:])
		}


		frame, frame_err := gpu.gpu_begin_frame(ctx)
		if !gpu.gpu_error_is_ok(frame_err) {
			free_all(context.temp_allocator)
			continue
		}

		// graph testing
		//
		if len(graph_data_global) > 0 {
			// the + 2 comes for the 2 extra bars we are going to render for coordinates
			//
			upload_data := make([]app.GraphGpuData, len(graph_data_global) + 2, context.temp_allocator)
			col_width := cast(f32)frame.extent.width / cast(f32)len(graph_data_global)
			x_off : f32 = 20.0
			for data, idx in graph_data_global {
				upload_data[idx] = app.ui_graph_charts_formalize_data(&graph_renderer, x_off, cast(f32)frame.extent.height + 10.0, col_width, data)
				ndc_mouse_pos : [2]f32 = {(cast(f32)ui_ctx.mouse_pos.x / cast(f32)frame.extent.width) * 2.0 - 1.0, (cast(f32)ui_ctx.mouse_pos.y / cast(f32)frame.extent.height) * 2.0 - 1.0}
				if ndc_mouse_pos.x >= upload_data[idx].top_left.x && ndc_mouse_pos.x <= upload_data[idx].bottom_right.x {
					if ndc_mouse_pos.y >= upload_data[idx].top_left.y && ndc_mouse_pos.y <= upload_data[idx].bottom_right.y {
						app_context.highlighted_row = idx
						upload_data[idx].color_top = {0.6, 0.15, 0.15, 1.0}
						upload_data[idx].color_bottom = {0.3, 0.15, 0.15, 1.0}
					}
				}
				x_off += col_width
			}

			// we build here for example the lines for reference data
			//
			upload_data[len(graph_data_global)]   = app.ui_graph_charts_formalize_data(&graph_renderer, 20, cast(f32)frame.extent.height + 5.0, 10.0, cast(f32)frame.extent.height / 2.0, {0.1, 0.1, 0.25, 1.0}, {0.1, 0.1, 0.35, 1.0})
			upload_data[len(graph_data_global)+1] = app.ui_graph_charts_formalize_data(&graph_renderer, 20, cast(f32)frame.extent.height + 5.0, cast(f32)frame.extent.width - 40.0, 10.0, {0.1, 0.1, 0.25, 1.0}, {0.1, 0.1, 0.35, 1.0})

			app.ui_graph_charts_push_data(&graph_renderer, upload_data)
		}

		current_scissor := vk.Rect2D{
			offset = {0, 0},
			extent = frame.extent,
		}
		app.ui_renderer_begin(ctx, &ui_renderer)

		{
			current_command: ^mui.Command
			for variant in mui.next_command_iterator(ui_ctx, &current_command) {
				switch cmd in variant {
				case ^mui.Command_Text:
					_font := cast(^gpu_text.Text_Font)cmd.font
					color : [4]f32 = {
						cast(f32)cmd.color.r / 255,
						cast(f32)cmd.color.g / 255,
						cast(f32)cmd.color.b / 255,
						cast(f32)cmd.color.a / 255
					}
					clip_rect := [4]f32{
						f32(current_scissor.offset.x),
						f32(current_scissor.offset.y),
						f32(current_scissor.offset.x) + f32(current_scissor.extent.width),
						f32(current_scissor.offset.y) + f32(current_scissor.extent.height),
					}
					app.ui_renderer_push_text(
						&ui_renderer,
						_font,
						cmd.str,
						f32(cmd.pos.x),
						f32(cmd.pos.y),
						color,
						clip_rect,
					)
				case ^mui.Command_Rect:
					color : [4]f32 = {
						cast(f32)cmd.color.r / 255,
						cast(f32)cmd.color.g / 255,
						cast(f32)cmd.color.b / 255,
						cast(f32)cmd.color.a / 255
					}
					clip_rect := [4]f32{
						f32(current_scissor.offset.x),
						f32(current_scissor.offset.y),
						f32(current_scissor.offset.x) + f32(current_scissor.extent.width),
						f32(current_scissor.offset.y) + f32(current_scissor.extent.height),
					}
					app.ui_renderer_push_rect(
						&ui_renderer,
						{f32(cmd.rect.x), f32(cmd.rect.y)},
						{f32(cmd.rect.x + cmd.rect.w), f32(cmd.rect.y + cmd.rect.h)},
						color,
						{color.r - 0.05, color.g - 0.05, color.b - 0.05, color.a},
						8,
						0,
						clip_rect,
					)
				case ^mui.Command_Icon:
					codepoint := ui_icon_codepoint(cmd.id)
					if codepoint != 0 {
						color := [4]f32{
							f32(cmd.color.r) / 255,
							f32(cmd.color.g) / 255,
							f32(cmd.color.b) / 255,
							f32(cmd.color.a) / 255,
						}
						clip_rect := [4]f32{
							f32(current_scissor.offset.x),
							f32(current_scissor.offset.y),
							f32(current_scissor.offset.x) + f32(current_scissor.extent.width),
							f32(current_scissor.offset.y) + f32(current_scissor.extent.height),
						}
						app.ui_renderer_push_icon(
							&ui_renderer,
							&ui_font_icon,
							codepoint,
							f32(cmd.rect.x),
							f32(cmd.rect.y),
							f32(cmd.rect.w),
							f32(cmd.rect.h),
							color,
							clip_rect,
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
				case ^mui.Command_Jump: 
					unreachable()
				}
			}
		}

		// Atlas copies must precede dynamic rendering so newly seen glyphs can be
		// sampled in this frame without an immediate queue submission or wait.
		gpu.gpu_upload_record(ctx, frame.cmd)
		gpu.gpu_begin_swapchain_rendering(ctx, frame, {
			clear = true,
			color = {0.02, 0.025, 0.04, 1.0},
		})
		app.ui_renderer_draw(ctx, &ui_renderer, frame.cmd, frame.extent)

		if len(graph_data_global) > 0 {
			app.ui_graph_charts_render(&graph_renderer, frame.cmd)
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
