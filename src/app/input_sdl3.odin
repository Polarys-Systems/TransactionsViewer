package app

when false {

/*
SDL3 input translation layer.

Example:
	input_begin_frame(&input)
	for SDL.PollEvent(&event) {
		input_process_sdl_event(&input, &event)
	}
	input_apply_to_ui(&input, &ui)
*/

max_scancodes :: 512

Mouse_Button :: enum {
	Left,
	Right,
	Middle,
	Count,
}

Key :: distinct SDL.Scancode

Input_State :: struct {
	mouse_pos:   [2]f32,
	mouse_delta: [2]f32,
	mouse_wheel: [2]f32,

	mouse_down:     [Mouse_Button.Count]bool,
	mouse_pressed:  [Mouse_Button.Count]bool,
	mouse_released: [Mouse_Button.Count]bool,

	key_down:     [max_scancodes]bool,
	key_pressed:  [max_scancodes]bool,
	key_released: [max_scancodes]bool,

	text_input: [dynamic]rune,
	_text_utf8: [dynamic]u8,

	quit_requested: bool,
	window_resized: bool,
	window_width:   i32,
	window_height:  i32,
}

Cursor_State :: struct {
	cursors: [ui.Cursor_Type]^SDL.Cursor,
	active: ui.Cursor_Type,
	active_valid: bool,
}

input_cursor_sdl_kind :: proc(cursor: ui.Cursor_Type) -> SDL.SystemCursor {
	#partial switch cursor {
	case .Arrow:
		return .DEFAULT
	case .Hand:
		return .POINTER
	case .Text_Input:
		return .TEXT
	case .Resize_Horizontal:
		return .EW_RESIZE
	case .Resize_Vertical:
		return .NS_RESIZE
	case .Resize_Diagonal_1:
		return .NWSE_RESIZE
	case .Resize_Diagonal_2:
		return .NESW_RESIZE
	case .Move:
		return .MOVE
	case .Forbidden:
		return .NOT_ALLOWED
	case:
		return .DEFAULT
	}
}

input_cursor_init :: proc(cursor_state: ^Cursor_State) {
	if cursor_state == nil {
		return
	}
	cursor_state^ = {}
}

input_cursor_shutdown :: proc(cursor_state: ^Cursor_State) {
	if cursor_state == nil {
		return
	}
	default_cursor := SDL.GetDefaultCursor()
	if default_cursor != nil {
		_ = SDL.SetCursor(default_cursor)
	}
	for cursor in ui.Cursor_Type {
		if cursor_state.cursors[cursor] != nil {
			SDL.DestroyCursor(cursor_state.cursors[cursor])
		}
	}
	cursor_state^ = {}
}

input_cursor_get_sdl :: proc(cursor_state: ^Cursor_State, cursor: ui.Cursor_Type) -> ^SDL.Cursor {
	if cursor_state == nil {
		return nil
	}
	if cursor_state.cursors[cursor] == nil {
		cursor_state.cursors[cursor] = SDL.CreateSystemCursor(input_cursor_sdl_kind(cursor))
		if cursor_state.cursors[cursor] == nil && cursor != .Arrow {
			cursor_state.cursors[cursor] = SDL.CreateSystemCursor(.DEFAULT)
		}
	}
	return cursor_state.cursors[cursor]
}

input_set_cursor :: proc(cursor_state: ^Cursor_State, cursor: ui.Cursor_Type) -> bool {
	if cursor_state == nil {
		return false
	}
	if cursor_state.active_valid && cursor_state.active == cursor {
		return true
	}
	sdl_cursor := input_cursor_get_sdl(cursor_state, cursor)
	if sdl_cursor == nil {
		return false
	}
	if SDL.SetCursor(sdl_cursor) {
		cursor_state.active = cursor
		cursor_state.active_valid = true
		return true
	}
	return false
}

input_apply_cursor_from_ui :: proc(cursor_state: ^Cursor_State, ui_ctx: ^ui.Context) -> bool {
	if ui_ctx == nil {
		return false
	}
	return input_set_cursor(cursor_state, ui.requested_cursor(ui_ctx))
}

key_from_scancode :: proc(scancode: SDL.Scancode) -> (ui.Key, bool) {
	#partial switch scancode {
	case .LSHIFT, .RSHIFT:
		return .SHIFT, true
	case .LCTRL, .RCTRL:
		return .CTRL, true
	case .LALT, .RALT:
		return .ALT, true
	case .LGUI, .RGUI:
		return .SUPER, true
	case .BACKSPACE:
		return .BACKSPACE, true
	case .DELETE:
		return .DELETE, true
	case .RETURN:
		return .RETURN, true
	case .ESCAPE:
		return .ESCAPE, true
	case .TAB:
		return .TAB, true
	case .LEFT:
		return .LEFT, true
	case .RIGHT:
		return .RIGHT, true
	case .UP:
		return .UP, true
	case .DOWN:
		return .DOWN, true
	case .HOME:
		return .HOME, true
	case .END:
		return .END, true
	case .A:
		return .A, true
	case .X:
		return .X, true
	case .C:
		return .C, true
	case .V:
		return .V, true
	case .Z:
		return .Z, true
	case .Y:
		return .Y, true
	case .K:
		return .K, true
	case .E:
		return .E, true
	case .SLASH:
		return .SLASH, true
	case:
		return .SHIFT, false
	}
}

mouse_button_index :: proc(button: u8) -> (Mouse_Button, bool) {
	switch button {
	case SDL.BUTTON_LEFT:
		return .Left, true
	case SDL.BUTTON_RIGHT:
		return .Right, true
	case SDL.BUTTON_MIDDLE:
		return .Middle, true
	case:
		return .Left, false
	}
}

scancode_index :: proc(scancode: SDL.Scancode) -> (int, bool) {
	idx := int(scancode)
	if idx < 0 || idx >= max_scancodes {
		return 0, false
	}
	return idx, true
}

input_begin_frame :: proc(input: ^Input_State) {
	input.mouse_delta = {}
	input.mouse_wheel = {}
	input.mouse_pressed = {}
	input.mouse_released = {}
	input.key_pressed = {}
	input.key_released = {}
	clear(&input.text_input)
	clear(&input._text_utf8)
	input.window_resized = false
}

input_process_sdl_event :: proc(input: ^Input_State, event: ^SDL.Event) {
	#partial switch event.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		input.quit_requested = true
	case .MOUSE_MOTION:
		next_pos := [2]f32{f32(event.motion.x), f32(event.motion.y)}
		input.mouse_delta[0] += next_pos[0] - input.mouse_pos[0]
		input.mouse_delta[1] += next_pos[1] - input.mouse_pos[1]
		input.mouse_pos = next_pos
	case .MOUSE_BUTTON_DOWN:
		if btn, ok := mouse_button_index(event.button.button); ok {
			input.mouse_down[btn] = true
			input.mouse_pressed[btn] = true
		}
		input.mouse_pos = {f32(event.button.x), f32(event.button.y)}
	case .MOUSE_BUTTON_UP:
		if btn, ok := mouse_button_index(event.button.button); ok {
			input.mouse_down[btn] = false
			input.mouse_released[btn] = true
		}
		input.mouse_pos = {f32(event.button.x), f32(event.button.y)}
	case .MOUSE_WHEEL:
		input.mouse_wheel[0] += f32(event.wheel.integer_x)
		input.mouse_wheel[1] += f32(event.wheel.integer_y)
	case .TEXT_INPUT:
		text_input, _ := strings.clone_from_cstring(event.text.text, context.temp_allocator)
		if len(text_input) > 0 {
			append(&input._text_utf8, ..transmute([]u8)text_input)
			for r in text_input {
				append(&input.text_input, r)
			}
		}
	case .KEY_DOWN:
		if idx, ok := scancode_index(event.key.scancode); ok {
			if !input.key_down[idx] {
				input.key_pressed[idx] = true
			}
			input.key_down[idx] = true
		}
	case .KEY_UP:
		if idx, ok := scancode_index(event.key.scancode); ok {
			input.key_down[idx] = false
			input.key_released[idx] = true
		}
	case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
		input.window_resized = true
		input.window_width = event.window.data1
		input.window_height = event.window.data2
	case:
	}
}

input_apply_to_ui :: proc(input: ^Input_State, ui_ctx: ^ui.Context) {
	input_apply_to_ui_scaled(input, ui_ctx, 1.0)
}

input_apply_to_ui_scaled :: proc(input: ^Input_State, ui_ctx: ^ui.Context, dpi_scale: f32) {
	scale := dpi_scale
	if scale <= 0 {
		scale = 1.0
	}
	mx := input.mouse_pos[0] * scale
	my := input.mouse_pos[1] * scale

	ui.input_reset(ui_ctx)
	ui.input_mouse_move(ui_ctx, mx, my)
	ui.input_mouse_delta(ui_ctx, input.mouse_delta[0] * scale, input.mouse_delta[1] * scale)

	for btn in Mouse_Button {
		if btn == .Count do continue
		mouse := ui.Mouse_Button.LEFT
		#partial switch btn {
		case .Left:
			mouse = .LEFT
		case .Right:
			mouse = .RIGHT
		case .Middle:
			mouse = .MIDDLE
		case:
		}
		ui.input_mouse_button(ui_ctx, mouse, input.mouse_down[btn], input.mouse_pressed[btn], input.mouse_released[btn])
	}

	if input.mouse_wheel[0] != 0 || input.mouse_wheel[1] != 0 {
		ui.input_scroll(ui_ctx, input.mouse_wheel[0], input.mouse_wheel[1])
	}

	if len(input.text_input) > 0 {
		ui.input_text(ui_ctx, input.text_input[:])
	}

	key_down: [ui.Key]bool
	key_pressed: [ui.Key]bool
	key_released: [ui.Key]bool
	for sc := SDL.Scancode(0); int(sc) < max_scancodes; sc = SDL.Scancode(int(sc) + 1) {
		if key, ok := key_from_scancode(sc); ok {
			idx := int(sc)
			key_down[key] = key_down[key] || input.key_down[idx]
			key_pressed[key] = key_pressed[key] || input.key_pressed[idx]
			key_released[key] = key_released[key] || input.key_released[idx]
		}
	}
	for key in ui.Key {
		ui.input_key(ui_ctx, key, key_down[key], key_pressed[key], key_released[key])
	}
}

input_key_pressed :: proc(input: ^Input_State, key: Key) -> bool {
	idx := int(SDL.Scancode(key))
	if idx < 0 || idx >= max_scancodes {
		return false
	}
	return input.key_pressed[idx]
}

input_mouse_pressed :: proc(input: ^Input_State, button: Mouse_Button) -> bool {
	return input.mouse_pressed[button]
}

}