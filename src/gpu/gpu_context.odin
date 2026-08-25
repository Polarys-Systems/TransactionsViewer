package gpu

import "core:c/libc"
import "base:runtime"
import vk "vendor:vulkan"

/*
GPU context bootstrap and per-frame orchestration.

Example:
	ctx, err := gpu_init()
	if !gpu_error_is_ok(err) do panic(err.message)
	defer gpu_shutdown(ctx)

	frame, frame_err := gpu_begin_frame(ctx)
	if !gpu_error_is_ok(frame_err) do return
	defer gpu_end_frame(ctx, frame)
*/

Gpu_Capabilities :: struct {
	has_unified_memory:        bool,
	has_resizable_bar_like_heap: bool,

	host_visible_device_local_memory:   bool,
	non_coherent_atom_size:             vk.DeviceSize,
	min_storage_buffer_offset_alignment: vk.DeviceSize,
	max_bindless_textures:               u32,
	max_bindless_samplers:               u32,
	max_bindless_uniform_buffers:        u32,
	max_update_after_bind_descriptors:   u32,
	max_push_constants_size:             u32,
}

Gpu_Context :: struct {
	base:         Vulkan_Base,
	desc:         Gpu_Desc,
	allocator:    runtime.Allocator,
	frame_index:  u64,
	capabilities: Gpu_Capabilities,
	upload:       Gpu_Upload_Context,
	frame_allocators: [max_frames_in_flight]Gpu_Frame_Allocator,
	bindless:       Gpu_Bindless_Heap,
	texture_slots: [dynamic]Texture_Slot,
	sampler_slots: [dynamic]Sampler_Slot,
	deletions:     [max_frames_in_flight]Gpu_Deletion_Queue,
}

Gpu_Frame :: struct {
	cmd:             vk.CommandBuffer,
	frame_slot:      u64,
	swapchain_image: u32,
	image:           vk.Image,
	view:            vk.ImageView,
	extent:          vk.Extent2D,
	format:          vk.Format,
	swapchain_generation: u64,
}

has_device_extension :: proc(device: vk.PhysicalDevice, extension_name: cstring) -> bool {
	extension_count: u32 = 0
	vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, nil)
	if extension_count == 0 {
		return false
	}

	extensions := make([]vk.ExtensionProperties, extension_count, context.temp_allocator)
	vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, raw_data(extensions))
	for i := u32(0); i < extension_count; i += 1 {
		if libc.strcmp(cstring(&extensions[i].extensionName[0]), extension_name) == 0 {
			return true
		}
	}
	return false
}

detect_capabilities :: proc(base: ^Vulkan_Base) -> Gpu_Capabilities {
	caps: Gpu_Capabilities

	props12 := vk.PhysicalDeviceVulkan12Properties{
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES,
	}
	props2: vk.PhysicalDeviceProperties2
	props2.sType = .PHYSICAL_DEVICE_PROPERTIES_2
	props2.pNext = &props12
	vk.GetPhysicalDeviceProperties2(base.Device.PhysicalDevice, &props2)
	caps.non_coherent_atom_size = props2.properties.limits.nonCoherentAtomSize
	caps.min_storage_buffer_offset_alignment = props2.properties.limits.minStorageBufferOffsetAlignment
	caps.max_push_constants_size = props2.properties.limits.maxPushConstantsSize
	caps.max_bindless_textures = min(
		props12.maxDescriptorSetUpdateAfterBindSampledImages,
		props12.maxPerStageDescriptorUpdateAfterBindSampledImages,
	)
	caps.max_bindless_samplers = min(
		props12.maxDescriptorSetUpdateAfterBindSamplers,
		props12.maxPerStageDescriptorUpdateAfterBindSamplers,
	)
	caps.max_bindless_uniform_buffers = min(
		props12.maxDescriptorSetUpdateAfterBindUniformBuffers,
		props12.maxPerStageDescriptorUpdateAfterBindUniformBuffers,
	)
	caps.max_update_after_bind_descriptors = props12.maxUpdateAfterBindDescriptorsInAllPools

	memory_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(base.Device.PhysicalDevice, &memory_props)

	has_device_local := false
	has_host_visible := false
	for i := u32(0); i < memory_props.memoryTypeCount; i += 1 {
		flags := memory_props.memoryTypes[i].propertyFlags
		if .DEVICE_LOCAL in flags {
			has_device_local = true
		}
		if .HOST_VISIBLE in flags {
			has_host_visible = true
		}
		if (.DEVICE_LOCAL in flags) && (.HOST_VISIBLE in flags) {
			caps.host_visible_device_local_memory = true
		}
	}

	// Heuristic: a single memory heap is often UMA/unified memory on integrated systems.
	caps.has_unified_memory = memory_props.memoryHeapCount == 1 || (has_device_local && has_host_visible && caps.host_visible_device_local_memory)

	// Heuristic for ReBAR-like behavior: directly CPU-visible device-local memory exists.
	caps.has_resizable_bar_like_heap = caps.host_visible_device_local_memory

	return caps
}

gpu_init :: proc(desc: ^Gpu_Desc = nil) -> (^Gpu_Context, Gpu_Error) {
	resolved := gpu_desc_default()
	if desc != nil {
		resolved = desc^
	}
	if resolved.bindless_texture_capacity == 0 do resolved.bindless_texture_capacity = default_texture_heap_capacity
	if resolved.bindless_sampler_capacity == 0 do resolved.bindless_sampler_capacity = default_sampler_heap_capacity
	if resolved.bindless_uniform_capacity == 0 do resolved.bindless_uniform_capacity = default_uniform_heap_capacity
	if resolved.frame_allocator_capacity == 0 do resolved.frame_allocator_capacity = frame_allocator_capacity
	if resolved.upload_staging_capacity == 0 do resolved.upload_staging_capacity = gpu_upload_default_staging_size

	allocator := context.allocator
	ctx := new(Gpu_Context, allocator)
	ctx.allocator = allocator
	base, err := gpu_base_init_with_desc(resolved)
	if !gpu_error_is_ok(err) {
		free(ctx, allocator)
		return nil, err
	}
	ctx.base = base
	ctx.desc = resolved
	ctx.frame_index = 0
	ctx.capabilities = detect_capabilities(&ctx.base)
	if resolved.bindless_texture_capacity > ctx.capabilities.max_bindless_textures ||
	   resolved.bindless_sampler_capacity > ctx.capabilities.max_bindless_samplers ||
	   resolved.bindless_uniform_capacity > ctx.capabilities.max_bindless_uniform_buffers ||
	   resolved.bindless_texture_capacity + resolved.bindless_sampler_capacity + resolved.bindless_uniform_capacity > ctx.capabilities.max_update_after_bind_descriptors {
		gpu_base_shutdown(&ctx.base)
		free(ctx, allocator)
		return nil, gpu_error(.Unsupported_Feature, "Requested bindless capacity exceeds Vulkan device limits")
	}
	gpu_upload_context_init(ctx)
	err = gpu_bindless_init(
		ctx,
		max(1, resolved.bindless_texture_capacity),
		max(1, resolved.bindless_sampler_capacity),
		max(1, resolved.bindless_uniform_capacity),
	)
	if !gpu_error_is_ok(err) {
		gpu_upload_context_shutdown(ctx)
		gpu_base_shutdown(&ctx.base)
		free(ctx, allocator)
		return nil, err
	}
	ctx.texture_slots = make([dynamic]Texture_Slot, 0, int(ctx.bindless.texture_capacity), allocator)
	ctx.sampler_slots = make([dynamic]Sampler_Slot, 0, int(ctx.bindless.sampler_capacity), allocator)
	frame_alloc_capacity := resolved.frame_allocator_capacity
	if frame_alloc_capacity == 0 {
		frame_alloc_capacity = frame_allocator_capacity
	}
	for i in 0..<int(ctx.base.FrameCount) {
		gpu_frame_allocator_init(ctx, &ctx.frame_allocators[i], frame_alloc_capacity)
	}

	gpu_log(&ctx.base, .Info, "Initialized GPU context")
	gpu_log(&ctx.base, .Debug, "Vulkan 1.3 + dynamic rendering + synchronization2 + BDA + descriptor indexing")
	return ctx, gpu_error_ok()
}

gpu_shutdown :: proc(ctx: ^Gpu_Context) {
	if ctx == nil {
		return
	}
	allocator := ctx.allocator
	if ctx.base.Device.LogicalDevice != nil {
		vk.DeviceWaitIdle(ctx.base.Device.LogicalDevice)
	}
	gpu_upload_flush(ctx)
	for i := 0; i < len(ctx.texture_slots); i += 1 {
		if ctx.texture_slots[i].alive {
			handle := Gpu_Texture_Handle(gpu_resource_handle_make(u32(i), ctx.texture_slots[i].generation))
			gpu_destroy_texture(ctx, handle)
		}
	}
	for i := 0; i < len(ctx.sampler_slots); i += 1 {
		if ctx.sampler_slots[i].alive {
			handle := Gpu_Sampler_Handle(gpu_resource_handle_make(u32(i), ctx.sampler_slots[i].generation))
			gpu_destroy_sampler(ctx, handle)
		}
	}
	if ctx.texture_slots != nil {
		delete(ctx.texture_slots)
		ctx.texture_slots = nil
	}
	if ctx.sampler_slots != nil {
		delete(ctx.sampler_slots)
		ctx.sampler_slots = nil
	}
	gpu_upload_context_shutdown(ctx)
	for i in 0..<int(ctx.base.FrameCount) {
		gpu_frame_allocator_shutdown(ctx, &ctx.frame_allocators[i])
	}
	gpu_deletion_queues_shutdown(ctx)
	gpu_bindless_shutdown(ctx)
	gpu_base_shutdown(&ctx.base)
	ctx^ = {}
	free(ctx, allocator)
}

gpu_wait_idle :: proc(ctx: ^Gpu_Context) {
	if ctx == nil do return
	vk.DeviceWaitIdle(ctx.base.Device.LogicalDevice)
	for slot in 0..<int(ctx.base.FrameCount) {
		gpu_collect_deletions(ctx, u32(slot))
	}
}

gpu_begin_frame :: proc(ctx: ^Gpu_Context) -> (Gpu_Frame, Gpu_Error) {
	err := gpu_prepare_frame(&ctx.base)
	if !gpu_error_is_ok(err) {
		return {}, err
	}
	gpu_collect_deletions(ctx, u32(ctx.base.CurrentFrame))

	gpu_upload_begin(ctx)
	cmd := gpu_begin_render(&ctx.base)
	frame := Gpu_Frame{
		cmd             = cmd,
		frame_slot      = ctx.base.CurrentFrame,
		swapchain_image = ctx.base.SwapchainImageIdx,
		image           = ctx.base.Swapchain.Images[ctx.base.SwapchainImageIdx],
		view            = ctx.base.Swapchain.ImageViews[ctx.base.SwapchainImageIdx],
		extent          = ctx.base.Swapchain.Extent,
		format          = ctx.base.Swapchain.Format,
		swapchain_generation = ctx.base.SwapchainGeneration,
	}
	// Reset the frame-local bump allocator before any per-draw root allocations happen.
	gpu_frame_allocator_reset(&ctx.frame_allocators[int(frame.frame_slot)])
	return frame, gpu_error_ok()
}

gpu_end_frame :: proc(ctx: ^Gpu_Context, frame: Gpu_Frame) -> Gpu_Error {
	frame_alloc := &ctx.frame_allocators[frame.frame_slot]
	if frame_alloc.offset > 0 {
		gpu_flush_buffer(&frame_alloc.buffer, 0, frame_alloc.offset)
	}
	gpu_upload_record(ctx, frame.cmd)
	gpu_upload_end(ctx)
	resized := gpu_end_render(&ctx.base, frame.cmd)
	ctx.frame_index += 1
	if resized {
		return gpu_error(.Swapchain_Out_Of_Date, "Swapchain became out of date while presenting")
	}
	return gpu_error_ok()
}

gpu_get_vk_command_buffer :: proc(frame: Gpu_Frame) -> vk.CommandBuffer {
	return frame.cmd
}

gpu_get_vk_device :: proc(ctx: ^Gpu_Context) -> vk.Device {
	return ctx.base.Device.LogicalDevice
}

gpu_get_vk_instance :: proc(ctx: ^Gpu_Context) -> vk.Instance {
	return ctx.base.Instance
}

gpu_get_vk_physical_device :: proc(ctx: ^Gpu_Context) -> vk.PhysicalDevice {
	return ctx.base.Device.PhysicalDevice
}

gpu_get_vk_graphics_queue :: proc(ctx: ^Gpu_Context) -> vk.Queue {
	return ctx.base.Device.GraphicsQueue
}

gpu_swapchain_format :: proc(ctx: ^Gpu_Context) -> vk.Format {
	return ctx.base.Swapchain.Format
}

gpu_swapchain_generation :: proc(ctx: ^Gpu_Context) -> u64 {
	return ctx.base.SwapchainGeneration
}

gpu_frames_in_flight :: proc(ctx: ^Gpu_Context) -> u32 {
	return ctx.base.FrameCount
}

gpu_current_frame_slot :: proc(ctx: ^Gpu_Context) -> u32 {
	return u32(ctx.base.CurrentFrame)
}

gpu_frame_index :: proc(ctx: ^Gpu_Context) -> u64 {
	return ctx.frame_index
}

gpu_swapchain_extent :: proc(ctx: ^Gpu_Context) -> vk.Extent2D {
	return ctx.base.Swapchain.Extent
}

gpu_swapchain_image :: proc(ctx: ^Gpu_Context, image_index: u32) -> vk.Image {
	assert(image_index < ctx.base.Swapchain.N_Images)
	return ctx.base.Swapchain.Images[image_index]
}
