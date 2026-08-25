package gpu

import vk "vendor:vulkan"

Gpu_Sampler_Handle :: distinct u32

Gpu_Sampler_Filter :: enum {
	Linear,
	Nearest,
}

Gpu_Sampler_Desc :: struct {
	filter:       Gpu_Sampler_Filter,
	address_mode: vk.SamplerAddressMode,
}

Sampler_Slot :: struct {
	generation: u32,
	alive:      bool,
	sampler:    vk.Sampler,
}

gpu_sampler_desc_default :: proc() -> Gpu_Sampler_Desc {
	return Gpu_Sampler_Desc{
		filter       = .Linear,
		address_mode = .CLAMP_TO_EDGE,
	}
}

gpu_sampler_handle_valid :: proc(handle: Gpu_Sampler_Handle) -> bool {
	return gpu_resource_handle_generation(u32(handle)) != 0
}

gpu_sampler_slot :: proc(ctx: ^Gpu_Context, handle: Gpu_Sampler_Handle) -> (^Sampler_Slot, u32, bool) {
	if ctx == nil || !gpu_sampler_handle_valid(handle) {
		return nil, 0, false
	}
	index := gpu_resource_handle_index(u32(handle))
	if index >= u32(len(ctx.sampler_slots)) {
		return nil, 0, false
	}
	slot := &ctx.sampler_slots[index]
	if !slot.alive || slot.generation != gpu_resource_handle_generation(u32(handle)) {
		return nil, 0, false
	}
	return slot, index, true
}

gpu_alloc_sampler_slot :: proc(ctx: ^Gpu_Context) -> (u32, u32, bool) {
	if ctx == nil || ctx.bindless.sampler_capacity == 0 {
		return 0, 0, false
	}

	for len(ctx.bindless.free_sampler_indices) > 0 {
		index := pop(&ctx.bindless.free_sampler_indices)
		if index >= u32(len(ctx.sampler_slots)) || ctx.sampler_slots[index].alive {
			continue
		}
		generation := ctx.sampler_slots[index].generation
		if generation == 0 {
			generation = 1
		}
		ctx.sampler_slots[index] = Sampler_Slot{generation = generation}
		return index, generation, true
	}

	if len(ctx.sampler_slots) >= int(ctx.bindless.sampler_capacity) {
		return 0, 0, false
	}
	index := u32(len(ctx.sampler_slots))
	append(&ctx.sampler_slots, Sampler_Slot{generation = 1})
	return index, 1, true
}

gpu_release_uncreated_sampler_slot :: proc(ctx: ^Gpu_Context, index: u32) {
	if ctx == nil || index >= u32(len(ctx.sampler_slots)) {
		return
	}
	generation := ctx.sampler_slots[index].generation
	ctx.sampler_slots[index] = Sampler_Slot{generation = generation}
	append(&ctx.bindless.free_sampler_indices, index)
}

gpu_create_sampler :: proc(ctx: ^Gpu_Context, desc: Gpu_Sampler_Desc) -> Gpu_Sampler_Handle {
	index, generation, ok := gpu_alloc_sampler_slot(ctx)
	if !ok {
		return Gpu_Sampler_Handle(0)
	}

	info := vk.SamplerCreateInfo{
		sType            = .SAMPLER_CREATE_INFO,
		pNext            = nil,
		addressModeU     = desc.address_mode,
		addressModeV     = desc.address_mode,
		addressModeW     = desc.address_mode,
		anisotropyEnable = false,
		maxAnisotropy    = 1.0,
		minLod           = 0.0,
		maxLod           = vk.LOD_CLAMP_NONE,
		borderColor      = .FLOAT_TRANSPARENT_BLACK,
	}
	switch desc.filter {
	case .Linear:
		info.magFilter = .LINEAR
		info.minFilter = .LINEAR
		info.mipmapMode = .LINEAR
	case .Nearest:
		info.magFilter = .NEAREST
		info.minFilter = .NEAREST
		info.mipmapMode = .NEAREST
	}

	sampler: vk.Sampler
	if vk.CreateSampler(ctx.base.Device.LogicalDevice, &info, nil, &sampler) != .SUCCESS {
		gpu_release_uncreated_sampler_slot(ctx, index)
		return Gpu_Sampler_Handle(0)
	}

	slot := &ctx.sampler_slots[index]
	slot.alive = true
	slot.sampler = sampler
	gpu_bindless_write_sampler(ctx, index, sampler)
	return Gpu_Sampler_Handle(gpu_resource_handle_make(index, generation))
}

gpu_destroy_sampler :: proc(ctx: ^Gpu_Context, handle: Gpu_Sampler_Handle) {
	slot, index, ok := gpu_sampler_slot(ctx, handle)
	if !ok {
		return
	}

	gpu_defer_sampler_destroy(ctx, slot.sampler, index)
	slot.sampler = vk.Sampler(0)
	slot.alive = false
	slot.generation = gpu_resource_handle_next_generation(slot.generation)
}

gpu_sampler_descriptor_index :: proc(ctx: ^Gpu_Context, handle: Gpu_Sampler_Handle) -> (u32, bool) {
	_, index, ok := gpu_sampler_slot(ctx, handle)
	return index, ok
}

gpu_sampler_vk :: proc(ctx: ^Gpu_Context, handle: Gpu_Sampler_Handle) -> vk.Sampler {
	slot, _, ok := gpu_sampler_slot(ctx, handle)
	if !ok {
		return vk.Sampler(0)
	}
	return slot.sampler
}
