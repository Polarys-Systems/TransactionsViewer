package app

import "core:fmt"
import "core:math"

import gpu "../gpu"
import gpu_text "../gpu_text"
import vk "vendor:vulkan"

// --------------------------------------------------------------- //

TimeFormatSimple :: enum {
	DD_MM_YYYY,
	YYYY_MM_DD,
	MM_DD_YYYY,

	hh_mm_ss,
	ss_mm_hh,

	hh_mm,
	hh,
}

TimeFormat :: bit_set[TimeFormatSimple;u16]

vec2 :: [2]f32 
vec3 :: [3]f32
vec4 :: [4]f32 

// --------------------------------------------------------------- //

GraphGpuData :: struct {
	top_left     : vec2, // 8 bytes
	bottom_right : vec2, // 8 bytes
	color_top    : vec4, // 12 bytes 
	color_bottom : vec4, // 12 bytes --> total : 40 bytes. 
}

// --------------------------------------------------------------- //

GraphChartPushConstantData :: struct {
	buffer_device_address : vk.DeviceAddress,
}
// --------------------------------------------------------------- //

GraphChartUniformData :: struct {

}
// --------------------------------------------------------------- //

GraphChartHoverInfo :: struct {

}
// --------------------------------------------------------------- //

GraphChartState :: struct {
	zoom_level  : f32,
	time_format : string,

	hover_info : GraphChartHoverInfo,

	gpu_buffer_addr : [gpu.max_frames_in_flight]vk.DeviceAddress,
	gpu_buffer      : [gpu.max_frames_in_flight]gpu.Gpu_Vertex_Buffer,
	uniform_data    : [gpu.max_frames_in_flight]GraphChartUniformData,
	push_data       : GraphChartPushConstantData,

	gpu_pipeline : gpu.Gpu_Pipeline,
	gpu_pipeline_desc : gpu.Gpu_Pipeline_Desc,

	gpu_ctx : ^gpu.Gpu_Context,
}

// --------------------------------------------------------------- //

ui_graph_charts_init :: proc(self : ^GraphChartState, gpu_ctx : ^gpu.Gpu_Context, allocator := context.allocator) {
	self.gpu_ctx = gpu_ctx

	self.gpu_buffer[0] = gpu.gpu_create_vertex_buffer(gpu_ctx, size_of(GraphGpuData), 1 << 20, {.STORAGE_BUFFER}, .Upload)
	self.gpu_buffer[1] = gpu.gpu_create_vertex_buffer(gpu_ctx, size_of(GraphGpuData), 1 << 20, {.STORAGE_BUFFER}, .Upload)

	self.gpu_buffer_addr = {self.gpu_buffer[0].Buffer.gpu, self.gpu_buffer[1].Buffer.gpu}

	push_ranges := []vk.PushConstantRange {
		{
			stageFlags = vk.ShaderStageFlags{.VERTEX},
			offset      = 0,
			size        = size_of(GraphChartPushConstantData),
		},
	}

	self.gpu_pipeline_desc = gpu.Gpu_Pipeline_Desc {
		VertShaderPath = "./shaders/graph_charts.vert.spv",
		FragShaderPath = "./shaders/graph_charts.frag.spv",
		VertShaderCode = #load("../../shaders/graph_charts.vert.spv"),
		FragShaderCode = #load("../../shaders/graph_charts.frag.spv"),
		VertEntryPoint = "main",
		FragEntryPoint = "main",
		// No buffer descriptors required if vertex/instance data
		// are accessed through BDA.
		DescriptorLayouts = nil,

		// Pass root GPU addresses / draw metadata here.
		PushConstants = push_ranges,

		// Empty because vertex shader manually fetches data
		// using gl_VertexIndex.
		VertexAttributes = nil,
		VertexBindings   = nil,

		Topology    = .TRIANGLE_LIST,
		PolygonMode = .FILL,

		CullMode = vk.CullModeFlags{},
		FrontFace = .COUNTER_CLOCKWISE,

		BlendMode = .ALPHA,

		DepthTest      = false,
		DepthWrite     = false,
		DepthCompareOp = .LESS_OR_EQUAL,

		ColorFormats = []vk.Format {
			gpu.gpu_swapchain_format(gpu_ctx),
		},

		DepthFormat = .UNDEFINED,
	}

	self.gpu_pipeline = gpu.gpu_create_graphics_pipeline(gpu_ctx, self.gpu_pipeline_desc)
}

// --------------------------------------------------------------- //

ui_graph_charts_destroy :: proc(self : ^GraphChartState) {
	gpu.gpu_destroy_vertex_buffer(self.gpu_ctx, &self.gpu_buffer[0])
	gpu.gpu_destroy_vertex_buffer(self.gpu_ctx, &self.gpu_buffer[1])

	gpu.gpu_destroy_pipeline(self.gpu_ctx, &self.gpu_pipeline)
}

// --------------------------------------------------------------- //

ui_graph_charts_formalize_data :: proc(self : ^GraphChartState, x, y, w, h : f32, color_top := vec4{0.25, 0.15, 0.15, 1.0}, color_bottom := vec4{0.3, 0.2, 0.2, 1.0}) -> (result : GraphGpuData) {

	win_size := self.gpu_ctx.base.Window.last_extent
	result = GraphGpuData {
		top_left = ({x, y - h} / {cast(f32)win_size.width, cast(f32)win_size.height}) * 2.0 - 1.0,
		bottom_right = ({x + w, y} / {cast(f32)win_size.width, cast(f32)win_size.height}) * 2.0 - 1.0,
		color_top = color_top,
		color_bottom = color_bottom
	}

	return result
}

// --------------------------------------------------------------- //

ui_graph_charts_push_data :: proc(self : ^GraphChartState, data : []GraphGpuData) {
	gpu.gpu_upload_vertices_raw(&self.gpu_buffer[gpu.gpu_current_frame_slot(self.gpu_ctx)], rawptr(&data[0]), len(data))
}

// --------------------------------------------------------------- //

ui_graph_charts_push_time :: proc(self : ^GraphChartState, time_array : []string, format : TimeFormat) {}

// --------------------------------------------------------------- //

ui_graph_charts_render :: proc(self : ^GraphChartState, cb : vk.CommandBuffer) {

	push_data := GraphChartPushConstantData {
		buffer_device_address = gpu.gpu_get_device_address(self.gpu_ctx, self.gpu_buffer[gpu.gpu_current_frame_slot(self.gpu_ctx)].Buffer.buffer)
	}

	gpu.gpu_bind_pipeline(self.gpu_ctx, cb, &self.gpu_pipeline)
	gpu.gpu_push_constants(self.gpu_ctx, cb, &self.gpu_pipeline, {.VERTEX}, &push_data, size_of(GraphChartPushConstantData), 0)

	vk.CmdDraw(cb, 6, cast(u32) self.gpu_buffer[gpu.gpu_current_frame_slot(self.gpu_ctx)].VertexCount, 0, 0)
}