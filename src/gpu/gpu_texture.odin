package gpu

import vma "../odin-vma"
import vk "vendor:vulkan"

/*
Texture and sampler handles use a 16-bit descriptor index and a 16-bit
generation. Generation zero is reserved, so the all-zero handle is invalid.
*/

gpu_resource_handle_index_bits       :: 16
gpu_resource_handle_generation_shift :: gpu_resource_handle_index_bits
gpu_resource_handle_index_mask       :: u32(0x0000ffff)
gpu_resource_handle_generation_mask  :: u32(0x0000ffff)
gpu_resource_handle_capacity         :: u32(65536)

gpu_resource_handle_make :: proc(index, generation: u32) -> u32 {
	if index >= gpu_resource_handle_capacity || generation == 0 {
		return 0
	}
	return ((generation & gpu_resource_handle_generation_mask) << gpu_resource_handle_generation_shift) |
	       (index & gpu_resource_handle_index_mask)
}

gpu_resource_handle_index :: proc(handle: u32) -> u32 {
	return handle & gpu_resource_handle_index_mask
}

gpu_resource_handle_generation :: proc(handle: u32) -> u32 {
	return (handle >> gpu_resource_handle_generation_shift) & gpu_resource_handle_generation_mask
}

gpu_resource_handle_next_generation :: proc(generation: u32) -> u32 {
	next := (generation + 1) & gpu_resource_handle_generation_mask
	if next == 0 {
		next = 1
	}
	return next
}

Gpu_Texture_Handle :: distinct u32

Gpu_Texture :: struct {
	image:            vk.Image,
	view:             vk.ImageView,
	allocation:       vma.Allocation,
	format:           vk.Format,
	extent:           vk.Extent3D,
	aspect:           vk.ImageAspectFlags,
	current_layout:   vk.ImageLayout,
	descriptor_index: u32,
}

Gpu_Texture_Desc :: struct {
	width:  u32,
	height: u32,
	format: vk.Format,
	usage:  vk.ImageUsageFlags,
}

Gpu_Image_Desc :: struct {
	type:           vk.ImageType,
	width:          u32,
	height:         u32,
	depth:          u32,
	mip_levels:     u32,
	array_layers:   u32,
	samples:        vk.SampleCountFlags,
	format:         vk.Format,
	usage:          vk.ImageUsageFlags,
	aspect:         vk.ImageAspectFlags,
	initial_layout: vk.ImageLayout,
	debug_name:     string,
}

Gpu_Texture_Update_Region :: struct {
	x:      u32,
	y:      u32,
	width:  u32,
	height: u32,
}

Texture_Slot :: struct {
	generation: u32,
	alive:      bool,
	tex:        Gpu_Texture,
}

gpu_texture_desc_2d :: proc(width, height: u32, format: vk.Format = .R8G8B8A8_UNORM) -> Gpu_Texture_Desc {
	return Gpu_Texture_Desc{
		width  = width,
		height = height,
		format = format,
		usage  = {.SAMPLED},
	}
}

gpu_image_desc_from_texture_desc :: proc(desc: Gpu_Texture_Desc) -> Gpu_Image_Desc {
	return Gpu_Image_Desc{
		type           = .D2,
		width          = desc.width,
		height         = desc.height,
		depth          = 1,
		mip_levels     = 1,
		array_layers   = 1,
		samples        = {._1},
		format         = desc.format,
		usage          = desc.usage + {.SAMPLED, .TRANSFER_DST},
		aspect         = {.COLOR},
		initial_layout = .UNDEFINED,
	}
}

gpu_texture_handle_valid :: proc(handle: Gpu_Texture_Handle) -> bool {
	return gpu_resource_handle_generation(u32(handle)) != 0
}

gpu_texture_slot :: proc(ctx: ^Gpu_Context, handle: Gpu_Texture_Handle) -> (^Texture_Slot, u32, bool) {
	if ctx == nil || !gpu_texture_handle_valid(handle) {
		return nil, 0, false
	}
	index := gpu_resource_handle_index(u32(handle))
	if index >= u32(len(ctx.texture_slots)) {
		return nil, 0, false
	}
	slot := &ctx.texture_slots[index]
	if !slot.alive || slot.generation != gpu_resource_handle_generation(u32(handle)) {
		return nil, 0, false
	}
	return slot, index, true
}

gpu_alloc_texture_slot :: proc(ctx: ^Gpu_Context) -> (u32, u32, bool) {
	if ctx == nil || ctx.bindless.texture_capacity == 0 {
		return 0, 0, false
	}

	for len(ctx.bindless.free_texture_indices) > 0 {
		index := pop(&ctx.bindless.free_texture_indices)
		if index >= u32(len(ctx.texture_slots)) || ctx.texture_slots[index].alive {
			continue
		}
		generation := ctx.texture_slots[index].generation
		if generation == 0 {
			generation = 1
		}
		ctx.texture_slots[index] = Texture_Slot{generation = generation}
		return index, generation, true
	}

	if len(ctx.texture_slots) >= int(ctx.bindless.texture_capacity) {
		return 0, 0, false
	}
	index := u32(len(ctx.texture_slots))
	append(&ctx.texture_slots, Texture_Slot{generation = 1})
	return index, 1, true
}

gpu_release_uncreated_texture_slot :: proc(ctx: ^Gpu_Context, index: u32) {
	if ctx == nil || index >= u32(len(ctx.texture_slots)) {
		return
	}
	generation := ctx.texture_slots[index].generation
	ctx.texture_slots[index] = Texture_Slot{generation = generation}
	append(&ctx.bindless.free_texture_indices, index)
}

gpu_image_view_type :: proc(image_type: vk.ImageType, array_layers: u32) -> (vk.ImageViewType, bool) {
	switch image_type {
	case .D1:
		if array_layers > 1 {
			return .D1_ARRAY, true
		}
		return .D1, true
	case .D2:
		if array_layers > 1 {
			return .D2_ARRAY, true
		}
		return .D2, true
	case .D3:
		if array_layers != 1 {
			return {}, false
		}
		return .D3, true
	}
	return {}, false
}

gpu_create_image :: proc(ctx: ^Gpu_Context, image_desc: Gpu_Image_Desc) -> Gpu_Texture_Handle {
	if ctx == nil || image_desc.width == 0 || image_desc.format == .UNDEFINED ||
	   image_desc.usage == {} || image_desc.aspect == {} {
		return Gpu_Texture_Handle(0)
	}

	array_layers := max(u32(1), image_desc.array_layers)
	size := vk.Extent3D{image_desc.width, image_desc.height, image_desc.depth}
	switch image_desc.type {
	case .D1:
		if image_desc.height > 1 || image_desc.depth > 1 {
			return Gpu_Texture_Handle(0)
		}
		size.height = 1
		size.depth = 1
	case .D2:
		if image_desc.height == 0 || image_desc.depth > 1 {
			return Gpu_Texture_Handle(0)
		}
		size.depth = 1
	case .D3:
		if image_desc.height == 0 || image_desc.depth == 0 || array_layers != 1 {
			return Gpu_Texture_Handle(0)
		}
	}

	view_type, valid_view_type := gpu_image_view_type(image_desc.type, array_layers)
	if !valid_view_type {
		return Gpu_Texture_Handle(0)
	}
	samples := image_desc.samples
	if samples == {} {
		samples = {._1}
	}

	slot_index, generation, slot_ok := gpu_alloc_texture_slot(ctx)
	if !slot_ok {
		return Gpu_Texture_Handle(0)
	}

	image_info := vk.ImageCreateInfo{
		sType         = .IMAGE_CREATE_INFO,
		pNext         = nil,
		imageType     = image_desc.type,
		format        = image_desc.format,
		extent        = size,
		mipLevels     = max(u32(1), image_desc.mip_levels),
		arrayLayers   = array_layers,
		samples       = samples,
		tiling        = .OPTIMAL,
		usage         = image_desc.usage,
		sharingMode   = .EXCLUSIVE,
		initialLayout = image_desc.initial_layout,
	}
	alloc_info := vma.AllocationCreateInfo{
		usage         = .GPU_ONLY,
		requiredFlags = {.DEVICE_LOCAL},
	}

	image: vk.Image
	allocation: vma.Allocation
	if vma.CreateImage(ctx.base.GPUAllocator, &image_info, &alloc_info, &image, &allocation, nil) != .SUCCESS {
		gpu_release_uncreated_texture_slot(ctx, slot_index)
		return Gpu_Texture_Handle(0)
	}

	view_info := vk.ImageViewCreateInfo{
		sType    = .IMAGE_VIEW_CREATE_INFO,
		pNext    = nil,
		image    = image,
		viewType = view_type,
		format   = image_desc.format,
		subresourceRange = {
			aspectMask     = image_desc.aspect,
			baseMipLevel   = 0,
			levelCount     = max(u32(1), image_desc.mip_levels),
			baseArrayLayer = 0,
			layerCount     = array_layers,
		},
	}
	image_view: vk.ImageView
	if vk.CreateImageView(ctx.base.Device.LogicalDevice, &view_info, nil, &image_view) != .SUCCESS {
		vma.DestroyImage(ctx.base.GPUAllocator, image, allocation)
		gpu_release_uncreated_texture_slot(ctx, slot_index)
		return Gpu_Texture_Handle(0)
	}

	slot := &ctx.texture_slots[slot_index]
	slot.alive = true
	slot.tex = Gpu_Texture{
		image            = image,
		view             = image_view,
		allocation       = allocation,
		format           = image_desc.format,
		extent           = size,
		aspect           = image_desc.aspect,
		current_layout   = image_desc.initial_layout,
		descriptor_index = slot_index,
	}
	return Gpu_Texture_Handle(gpu_resource_handle_make(slot_index, generation))
}

gpu_write_sampled_texture_descriptor :: proc(ctx: ^Gpu_Context, handle: Gpu_Texture_Handle) {
	slot, _, ok := gpu_texture_slot(ctx, handle)
	if !ok {
		return
	}
	gpu_bindless_write_texture(ctx, slot.tex.descriptor_index, slot.tex.view)
}

gpu_create_texture :: proc(ctx: ^Gpu_Context, desc: Gpu_Texture_Desc, data: []u8 = nil) -> Gpu_Texture_Handle {
	handle := gpu_create_image(ctx, gpu_image_desc_from_texture_desc(desc))
	slot, _, ok := gpu_texture_slot(ctx, handle)
	if !ok {
		return Gpu_Texture_Handle(0)
	}

	if len(data) > 0 {
		gpu_update_texture(ctx, handle, Gpu_Texture_Update_Region{width = desc.width, height = desc.height}, data)
	} else {
		cmd := gpu_immediate_submit_begin(&ctx.base)
		gpu_transition_image(cmd, slot.tex.image, slot.tex.current_layout, .SHADER_READ_ONLY_OPTIMAL)
		gpu_immediate_submit_end(&ctx.base, cmd)
		slot.tex.current_layout = .SHADER_READ_ONLY_OPTIMAL
	}
	gpu_write_sampled_texture_descriptor(ctx, handle)
	return handle
}

gpu_destroy_texture :: proc(ctx: ^Gpu_Context, handle: Gpu_Texture_Handle) {
	slot, index, ok := gpu_texture_slot(ctx, handle)
	if !ok {
		return
	}

	gpu_defer_texture_destroy(ctx, slot.tex.image, slot.tex.view, slot.tex.allocation, index)
	slot.tex = {}
	slot.alive = false
	slot.generation = gpu_resource_handle_next_generation(slot.generation)
}

gpu_update_texture :: proc(ctx: ^Gpu_Context, handle: Gpu_Texture_Handle, region: Gpu_Texture_Update_Region, data: []u8) {
	slot, index, ok := gpu_texture_slot(ctx, handle)
	if !ok || len(data) == 0 {
		return
	}

	update_region := region
	if update_region.width == 0 || update_region.height == 0 {
		update_region.width = slot.tex.extent.width
		update_region.height = slot.tex.extent.height
	}

	gpu_upload_enqueue_texture_copy(ctx, handle, Gpu_Image_Upload_Desc{
		region            = update_region,
		final_layout      = .SHADER_READ_ONLY_OPTIMAL,
		update_descriptor = true,
	}, data)
	gpu_upload_flush(ctx)
}

gpu_texture_descriptor_index :: proc(ctx: ^Gpu_Context, handle: Gpu_Texture_Handle) -> (u32, bool) {
	slot, _, ok := gpu_texture_slot(ctx, handle)
	if !ok {
		return 0, false
	}
	return slot.tex.descriptor_index, true
}

gpu_texture_alive :: proc(ctx: ^Gpu_Context, handle: Gpu_Texture_Handle) -> bool {
	_, _, ok := gpu_texture_slot(ctx, handle)
	return ok
}

gpu_texture_extent_2d :: proc(ctx: ^Gpu_Context, handle: Gpu_Texture_Handle) -> vk.Extent2D {
	slot, _, ok := gpu_texture_slot(ctx, handle)
	if !ok {
		return {}
	}
	return vk.Extent2D{slot.tex.extent.width, slot.tex.extent.height}
}

gpu_texture_view :: proc(ctx: ^Gpu_Context, handle: Gpu_Texture_Handle) -> vk.ImageView {
	slot, _, ok := gpu_texture_slot(ctx, handle)
	if !ok {
		return vk.ImageView(0)
	}
	return slot.tex.view
}

gpu_texture_image :: proc(ctx: ^Gpu_Context, handle: Gpu_Texture_Handle) -> vk.Image {
	slot, _, ok := gpu_texture_slot(ctx, handle)
	if !ok {
		return vk.Image(0)
	}
	return slot.tex.image
}

gpu_texture_layout :: proc(ctx: ^Gpu_Context, handle: Gpu_Texture_Handle) -> vk.ImageLayout {
	slot, _, ok := gpu_texture_slot(ctx, handle)
	if !ok {
		return .UNDEFINED
	}
	return slot.tex.current_layout
}

gpu_transition_texture :: proc(ctx: ^Gpu_Context, cmd: vk.CommandBuffer, handle: Gpu_Texture_Handle, new_layout: vk.ImageLayout) {
	slot, _, ok := gpu_texture_slot(ctx, handle)
	if !ok || slot.tex.current_layout == new_layout {
		return
	}
	gpu_transition_image_aspect(cmd, slot.tex.image, slot.tex.current_layout, new_layout, slot.tex.aspect)
	slot.tex.current_layout = new_layout
	if new_layout == .SHADER_READ_ONLY_OPTIMAL {
		gpu_write_sampled_texture_descriptor(ctx, handle)
	}
}
