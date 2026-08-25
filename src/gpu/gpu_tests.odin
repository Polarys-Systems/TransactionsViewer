package gpu

import "core:testing"
import vk "vendor:vulkan"

@(test)
gpu_resource_handle_round_trip :: proc(t: ^testing.T) {
	handle := gpu_resource_handle_make(42, 7)
	testing.expect(t, handle != 0)
	testing.expect_value(t, gpu_resource_handle_index(handle), u32(42))
	testing.expect_value(t, gpu_resource_handle_generation(handle), u32(7))
	testing.expect_value(t, gpu_resource_handle_next_generation(0xffff), u32(1))
}

@(test)
gpu_default_contract :: proc(t: ^testing.T) {
	desc := gpu_desc_default()
	testing.expect_value(t, desc.frames_in_flight, u32(2))
	testing.expect(t, desc.enable_validation == ODIN_DEBUG)
	testing.expect(t, desc.window.resizable)
	testing.expect(t, desc.window.high_pixel_density)
	testing.expect(t, desc.bindless_texture_capacity > 0)
	testing.expect(t, desc.bindless_sampler_capacity > 0)
	testing.expect(t, desc.bindless_uniform_capacity > 0)
}

@(test)
gpu_composite_alpha_selection :: proc(t: ^testing.T) {
	alpha, ok := choose_composite_alpha({}, {.OPAQUE, .INHERIT})
	testing.expect(t, ok)
	testing.expect(t, alpha == vk.CompositeAlphaFlagsKHR{.OPAQUE})

	_, unsupported := choose_composite_alpha({.PRE_MULTIPLIED}, {.OPAQUE})
	testing.expect(t, !unsupported)
}
