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
MAX_LAYOUT     :: #config(MAX_STYLES, 128)

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

UiAlignment :: enum {
	NONE, 
	RIGHT,
	CENTER,
	TOP,
	BOTTOM,
}

UiAlignments :: bit_set[UiAlignment;u8]

// --------------------------------------------------------------- //

UiAction :: enum {
	NONE, 
	HOVERABLE,
	CLICKABLE,
	RIGHT_CLICKABLE,
	SCROLLABLE,
	RESIZABLE,
	CLOSABLE,
	NO_CLIPPING,
	EDITABLE,
}

UiActions :: bit_set[UiAction;u16]

// --------------------------------------------------------------- //

UiIcon :: enum {
	NONE,
	CHECK,
	CHECK_UNCHECKED,
	RESIZE, 
	CLOSE,
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

default_style :: UiStyle {
	font_id = 0,
	color_top = {0.2, 0.2, 0.2, 1.0},
	color_bottom = {0.15, 0.15, 0.15, 1.0},
	radius = 4,
	edge   = 2, 
	border = 0
}

// --------------------------------------------------------------- //

UiBox :: struct {
	zindex        : i32,
	rect          : Rect2d,
	boundary_rect : Rect2d,
	scroll_offset : [2]f32,
	text          : strings.Builder,
	style         : UiStyle,
	childs        : ^[MAX_BOXES]UiBox,
}

// --------------------------------------------------------------- //

UiLayout :: struct {
	rect      : Rect2d,
	content   : Rect2d,
	margin    : f32,
	alignment : UiAlignments,
	box_size  : [2]f32,
	scrollable_content : [2]f32,
	column_width : f32,
}

// --------------------------------------------------------------- //

default_layout :: UiLayout {
	rect      = {-1, -1, -1, -1},
	content   = {-1, -1, 0, 0},
	box_size  = {140, 40},
	margin    = 4,
	alignment = {.NONE}
}

// --------------------------------------------------------------- //

UiContext :: struct {
	allocator : runtime.Allocator,

	screen        : Rect2d,
	delta_time    : f32,
	delta_mouse   : [2]f32,
	mouse_pos     : [2]f32,

	windows       : [MAX_WINDOWS]UiBox,
	pop_out_boxes : [MAX_BOXES]UiBox,
	menu          : [MAX_MENU_BOXES]UiBox,
	command_bar   : [MAX_COMMANDS]UiBox,

	n_windows       : i32,
	n_pop_out_boxes : i32,
	n_menu_boxes    : i32,
	n_commands      : i32,

	// styling
	//
	styles : [MAX_STYLES]UiStyle,
	n_styles : i32,

	// layout 
	// 
	layouts : [MAX_LAYOUT]UiLayout,
	n_layouts : i32,
}

// --------------------------------------------------------------- //

clip_rect :: proc(rect : Rect2d, point : [2]f32) -> bool {
	if(point.x >= rect.x && point.x <= rect.x + rect.width) {
		if(point.y >= rect.y && point.y <= rect.y + rect.height) {
			return true 
		}
	}

	return false
}

// --------------------------------------------------------------- //

init :: proc(allocator := context.allocator ) -> (context_t : ^UiContext) {
	context_t.allocator = allocator

	return context_t
}

// --------------------------------------------------------------- //

begin :: proc(self : ^UiContext, window_w, window_h : f32) {
	self.screen.width    = window_w
	self.screen.height   = window_h
	self.n_windows       = -1
	self.n_pop_out_boxes = -1
	self.n_menu_boxes    = -1
	self.n_commands      = -1
	self.n_styles        = -1
	self.n_layouts       = -1
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

	style_push(self)

	return self, true
}

// --------------------------------------------------------------- //

end_window :: proc(self : ^UiContext, close : bool) {

}

// --------------------------------------------------------------- //

new_box :: proc(self : ^UiContext, str : string, alignment : UiAlignments, actions : UiActions, rect : Rect2d) {
	
}

// --------------------------------------------------------------- //

// button amplified with args
button_am :: proc(self : ^UiContext, str : string, rect : Rect2d = {-1, -1, -1, -1}, align := UiAlignments{.CENTER}) {

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

style_push :: proc(self : ^UiContext, style : UiStyle = default_style) {
	self.n_styles += 1;
	assert(self.n_styles < MAX_STYLES)

	self.styles[self.n_styles] = style
}

// --------------------------------------------------------------- //

style_push_font :: proc(self : ^UiContext, font : UiFont) {
	assert(self.n_styles >= 0)

	self.styles[self.n_styles].font_id = font
}

// --------------------------------------------------------------- //

style_push_color :: proc(self : ^UiContext, color_top : [4]f32, color_bottom : [4]f32) {
	assert(self.n_styles >= 0)

	self.styles[self.n_styles].color_top[0] = color_top[0];
	self.styles[self.n_styles].color_top[1] = color_top[1];
	self.styles[self.n_styles].color_top[2] = color_top[2];
	self.styles[self.n_styles].color_top[3] = color_top[3];

	self.styles[self.n_styles].color_bottom[0] = color_bottom[0];
	self.styles[self.n_styles].color_bottom[1] = color_bottom[1];
	self.styles[self.n_styles].color_bottom[2] = color_bottom[2];
	self.styles[self.n_styles].color_bottom[3] = color_bottom[3];
}

// --------------------------------------------------------------- //

style_push_radius :: proc(self : ^UiContext, radius : f32) {
	assert(self.n_styles >= 0)

	self.styles[self.n_styles].radius = radius
}

// --------------------------------------------------------------- //

style_push_border :: proc(self : ^UiContext, border : f32) {
	assert(self.n_styles >= 0)

	self.styles[self.n_styles].border = border
}

// --------------------------------------------------------------- //

style_push_edge :: proc(self : ^UiContext, edge : f32) {
	assert(self.n_styles >= 0)

	self.styles[self.n_styles].edge = edge
}

// --------------------------------------------------------------- //

layout_push :: proc(self: ^UiContext, layout := default_layout) {
	self.n_layouts += 1
	assert(self.n_layouts < MAX_LAYOUT)

	self.layouts[self.n_layouts] = layout
}

// --------------------------------------------------------------- //

layout_push_content :: proc(self: ^UiContext, content : Rect2d) {
	assert(self.n_layouts >= 0)
	
	self.layouts[self.n_layouts].content = content 	
}

// --------------------------------------------------------------- //

layout_push_rect :: proc(self: ^UiContext, rect : Rect2d) {
	assert(self.n_layouts >= 0)
	
	self.layouts[self.n_layouts].rect = rect 	
}

// --------------------------------------------------------------- //

layout_push_box_size :: proc(self: ^UiContext, box_size : [2]f32) {
	assert(self.n_layouts >= 0)
	
	self.layouts[self.n_layouts].box_size[0] = box_size[0] 	
	self.layouts[self.n_layouts].box_size[1] = box_size[1] 	
}

// --------------------------------------------------------------- //

layout_push_margin :: proc(self: ^UiContext, margin : f32) {
	assert(self.n_layouts >= 0)
	
	self.layouts[self.n_layouts].margin = margin 	
}

// --------------------------------------------------------------- //

layout_push_alignment :: proc(self: ^UiContext, alignments : UiAlignments) {
	assert(self.n_layouts >= 0)
	
	self.layouts[self.n_layouts].alignment = alignments
}

// --------------------------------------------------------------- //

layout_begin_scroll :: proc(self : ^UiContext, auto_h_scroll := true) {

}

// --------------------------------------------------------------- //

layout_end_scroll :: proc(self : ^UiContext, auto_h_scroll := true) {

}

// --------------------------------------------------------------- //

layout_row :: proc(self : ^UiContext, n_columns := 1) {
	assert(self.n_layouts >= 0 && self.n_layouts < MAX_LAYOUT)
	n_layouts := self.n_layouts

	self.layouts[n_layouts].column_width = self.layouts[n_layouts].rect.width / auto_cast n_columns
	self.layouts[n_layouts].content.x    = self.layouts[n_layouts].rect.x

	self.layouts[n_layouts].content.y -= self.layouts[n_layouts].box_size.y
}