package ui 

import "core:strings"

// --------------------------------------------------------------- //

UiResult :: enum {
	Ok,
}

// --------------------------------------------------------------- //

Rect2d :: struct {
	x, y : f32
	width, height : f32, 
}

rect2d_set_start :: proc(self: ^rect2d, x, y : f32) {
	self.x = x;
	self.y = y;
}

rect2d_set_offset :: proc(self: ^rect2d, w, h : f32) {
	self.width  = w;
	self.height = h;
}

// --------------------------------------------------------------- //

UiBox :: struct {
	rect : Rect2d,
	boundary_rect : Rect2d,
	color : [4]f32,
	text : strings.Builder,
}

// --------------------------------------------------------------- //

UiContext :: struct {
	screen        : Rect2d,
	delta_time    : f32,
	delta_mouse   : [2]f32,
	mouse_pos     : [2]f32,

	boxes         : [dynamic]UiBox,
	pop_out_boxes : [dynamic]UiBox,
	menu          : [dynamic]UiBox,
	command_bar   : [dynamic]UiBox,
}

UiContext_init :: proc() -> UiContext {
	context_t := UiContext;

	return context_t;
}

UiContext_set_screen :: proc(self : ^UiContext, screen : Rect2d) {
	self.screen = screen;
}

UiContext_set_delta_time :: proc(self : ^UiContext, delta_time : f32) {
	self.delta_time = delta_time;
}

UiContext_set_delta_mouse :: proc(self : ^UiContext, delta_mouse : [2]f32) {
	self.delta_mouse[0] = delta_mouse[0];
	self.delta_mouse[1] = delta_mouse[1];
}

UiContext_set_mouse_pos :: proc(self : ^UiContext, mouse_pos : [2]f32) {
	self.mouse_pos[0] = mouse_pos[0];
	self.mouse_pos[1] = mouse_pos[1];
}

// --------------------------------------------------------------- //
