package gpu

import "core:fmt"
import vk "vendor:vulkan"

Gpu_Result :: enum {
	Ok,
	Vulkan_Error,
	Sdl_Error,
	Invalid_Argument,
	Out_Of_Memory,
	Unsupported_Feature,
	Swapchain_Out_Of_Date,
	Not_Ready,
}

Gpu_Error :: struct {
	result:    Gpu_Result,
	vk_result: vk.Result,
	message:   string,
}

gpu_error_ok :: proc() -> Gpu_Error {
	return Gpu_Error{result = .Ok, vk_result = .SUCCESS}
}

gpu_error_is_ok :: proc(err: Gpu_Error) -> bool {
	return err.result == .Ok
}

Gpu_Log_Level :: enum {
	Debug,
	Info,
	Warning,
	Error,
}

Gpu_Log_Callback :: proc(level: Gpu_Log_Level, message: string, user_data: rawptr)
Gpu_Device_Filter :: proc(device: vk.PhysicalDevice, user_data: rawptr) -> bool

Gpu_Window_Desc :: struct {
	title:              string,
	width:              i32,
	height:             i32,
	resizable:          bool,
	high_pixel_density: bool,
	hidden:             bool,
	borderless:         bool,
	fullscreen:         bool,
}

gpu_window_desc_default :: proc() -> Gpu_Window_Desc {
	return Gpu_Window_Desc{
		title = "Polaris System",
		width = 1200,
		height = 1200,
		resizable = true,
		high_pixel_density = true,
	}
}

Gpu_Desc :: struct {
	app_name: string,
	window:   Gpu_Window_Desc,

	enable_validation: bool,
	frames_in_flight:  u32,

	required_instance_extensions: []cstring,
	optional_instance_extensions: []cstring,
	instance_flags:               vk.InstanceCreateFlags,
	instance_pnext:               rawptr,

	required_device_extensions: []cstring,
	optional_device_extensions: []cstring,
	device_features_pnext:       rawptr,
	device_filter:               Gpu_Device_Filter,
	device_user_data:            rawptr,

	swapchain: Gpu_Swapchain_Desc,

	bindless_texture_capacity: u32,
	bindless_sampler_capacity: u32,
	bindless_uniform_capacity: u32,
	frame_allocator_capacity:  u64,
	upload_staging_capacity:   u64,

	log_callback:  Gpu_Log_Callback,
	log_user_data: rawptr,
}

gpu_desc_default :: proc() -> Gpu_Desc {
	return Gpu_Desc{
		app_name = "Polaris System",
		window = gpu_window_desc_default(),
		enable_validation = ODIN_DEBUG,
		frames_in_flight = 2,
		swapchain = gpu_swapchain_desc_default(),
		bindless_texture_capacity = default_texture_heap_capacity,
		bindless_sampler_capacity = default_sampler_heap_capacity,
		bindless_uniform_capacity = default_uniform_heap_capacity,
		frame_allocator_capacity = frame_allocator_capacity,
		upload_staging_capacity = gpu_upload_default_staging_size,
	}
}

gpu_log_fallback :: proc(level: Gpu_Log_Level, message: string, user_data: rawptr) {
	_ = user_data
	prefix := "[GPU]"
	switch level {
	case .Debug:
		prefix = "[GPU][DEBUG]"
	case .Info:
		prefix = "[GPU][INFO]"
	case .Warning:
		prefix = "[GPU][WARN]"
	case .Error:
		prefix = "[GPU][ERROR]"
	}
	fmt.println(prefix, message)
}
