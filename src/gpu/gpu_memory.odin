package gpu

import vk "vendor:vulkan"

/*
GPU memory classes + transient allocation views.

Example:
	buffer := gpu_create_buffer(ctx, 64 * 1024, {.UNIFORM_BUFFER}, .Upload, "ui-uniforms")
*/

Gpu_Memory_Kind :: enum {
	Auto,
	Upload,
	Device,
	Readback,
	Transient_Frame,
}

Gpu_Temp_Allocation :: struct {
	cpu:  rawptr,
	gpu:  vk.DeviceAddress,
	size: u64,
}

Gpu_Temp_Typed :: struct($T: typeid) {
	cpu:  ^T,
	gpu:  vk.DeviceAddress,
	size: u64,
}

align_up_u64 :: proc(value, alignment: u64) -> u64 {
	if alignment <= 1 {
		return value
	}
	mask := alignment - 1
	return (value + mask) & ~mask
}
