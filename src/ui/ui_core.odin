package ui 

import "base:runtime"
import "core:strings"

// --------------------------------------------------------------- // 
// Default configs
MAX_BOXES      :: #config(MAX_BOXES, 4096)
MAX_WINDOWS    :: #config(MAX_WINDOWS, 128)
MAX_MENU_BOXES :: #config(MAX_MENU_BOXES, 64)
MAX_COMMANDS   :: #config(MAX_COMMANDS, 1024) 
MAX_STYLES     :: #config(MAX_STYLES, 128)

// --------------------------------------------------------------- //

UiResult :: enum {
	OK,
	ACTIVE,
	NOT_ACTIVE,
	SUBMIT,
	MODIFIED,
	PRESSED,
	RELEASED,
}

// --------------------------------------------------------------- //

Rect2d :: struct {
	x, y : f32,
	width, height : f32, 
}

rect2d_set_start :: proc(self: ^Rect2d, x, y : f32) {
	self.x = x;
	self.y = y;
}

rect2d_set_offset :: proc(self: ^Rect2d, w, h : f32) {
	self.width  = w;
	self.height = h;
}

// --------------------------------------------------------------- //

UiFont :: distinct uintptr 

// --------------------------------------------------------------- //

UiStyle :: struct {
	font_id      : UiFont,
	color_top    : [4]f32,
	color_bottom : [4]f32,
	radius : f32,
	edge   : f32,
	border : f32
}

// --------------------------------------------------------------- //

UiBox :: struct {
	rect          : Rect2d,
	boundary_rect : Rect2d,
	text          : strings.Builder,
	style         : UiStyle
}

// --------------------------------------------------------------- //

UiContext :: struct {
	allocator : runtime.Allocator,

	screen        : Rect2d,
	delta_time    : f32,
	delta_mouse   : [2]f32,
	mouse_pos     : [2]f32,

	windows       : [MAX_WINDOWS]UiBox,
	boxes         : [MAX_BOXES]UiBox,
	pop_out_boxes : [MAX_BOXES]UiBox,
	menu          : [MAX_MENU_BOXES]UiBox,
	command_bar   : [MAX_COMMANDS]UiBox,

	n_windows       : i32,
	n_boxes         : i32,
	n_pop_out_boxes : i32,
	n_menu_boxes    : i32,
	n_commands      : i32,

	// styling
	//
	styles : [MAX_STYLES]UiStyle
}

// --------------------------------------------------------------- //

init :: proc( allocator := context.allocator ) -> (context_t : ^UiContext) {
	context_t.allocator = allocator

	return context_t
}

// --------------------------------------------------------------- //

begin :: proc(self : ^UiContext, window_w, window_h : f32) {
	self.screen.width = window_w
	self.screen.height = window_h
	self.n_windows = -1
	self.n_boxes = -1
	self.n_pop_out_boxes = -1
	self.n_menu_boxes = -1
	self.n_commands = -1
}

// --------------------------------------------------------------- //

end :: proc(self : ^UiContext) {

}

// --------------------------------------------------------------- //

@(deferred_out=end_window)
begin_window :: proc(self : ^UiContext, win_rect : Rect2d) -> (^UiContext, bool) {
	self.n_windows += 1; // starts at -1, thus, we first increase
	assert(self.n_windows < MAX_WINDOWS)

	self.windows[self.n_windows] = UiBox {
		rect = win_rect,
		boundary_rect = win_rect,
	}

	return self, true
}

// --------------------------------------------------------------- //

end_window :: proc(self : ^UiContext, close : bool) {

}

// --------------------------------------------------------------- //

set_screen :: proc(self : ^UiContext, screen : Rect2d) {
	self.screen = screen;
}

// --------------------------------------------------------------- //

set_delta_time :: proc(self : ^UiContext, delta_time : f32) {
	self.delta_time = delta_time;
}

// --------------------------------------------------------------- //

set_delta_mouse :: proc(self : ^UiContext, delta_mouse : [2]f32) {
	self.delta_mouse[0] = delta_mouse[0];
	self.delta_mouse[1] = delta_mouse[1];
}

// --------------------------------------------------------------- //

set_mouse_pos :: proc(self : ^UiContext, mouse_pos : [2]f32) {
	self.mouse_pos[0] = mouse_pos[0];
	self.mouse_pos[1] = mouse_pos[1];
}

// --------------------------------------------------------------- //
