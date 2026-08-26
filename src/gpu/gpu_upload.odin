package gpu

import "core:c/libc"

import vk "vendor:vulkan"

gpu_upload_default_staging_size :: 8 * 1024 * 1024

Gpu_Pending_Buffer_Copy :: struct {
	src_offset: u64,
	dst:        vk.Buffer,
	dst_offset: u64,
	size:       u64,
}

Gpu_Pending_Image_Copy :: struct {
	src_offset:   u64,
	texture:      Gpu_Texture_Handle,
	region:       Gpu_Texture_Update_Region,
	final_layout: vk.ImageLayout,
}

Gpu_Image_Upload_Desc :: struct {
	region:       Gpu_Texture_Update_Region,
	final_layout: vk.ImageLayout,
}

Gpu_Upload_Arena :: struct {
	staging:          Gpu_Buffer,
	staging_capacity: u64,
	staging_head:     u64,
	dirty_start:      u64,
	dirty_end:        u64,
	dirty:            bool,
	recorded:         bool,
	retired_staging:  [dynamic]Gpu_Buffer,
	pending_buffers:  [dynamic]Gpu_Pending_Buffer_Copy,
	pending_images:   [dynamic]Gpu_Pending_Image_Copy,
}

Gpu_Touched_Image :: struct {
	texture:      Gpu_Texture_Handle,
	final_layout: vk.ImageLayout,
}

Gpu_Upload_Context :: struct {
	frames:      [max_frames_in_flight]Gpu_Upload_Arena,
	immediate:   Gpu_Upload_Arena,
	active_slot: u32,
	in_frame:    bool,
}

gpu_upload_arena_init :: proc(arena: ^Gpu_Upload_Arena, capacity: u64) {
	arena^ = {
		staging_capacity = capacity,
		retired_staging = make([dynamic]Gpu_Buffer, 0, 2),
		pending_buffers = make([dynamic]Gpu_Pending_Buffer_Copy, 0, 64),
		pending_images = make([dynamic]Gpu_Pending_Image_Copy, 0, 64),
	}
}

gpu_upload_arena_shutdown :: proc(ctx: ^Gpu_Context, arena: ^Gpu_Upload_Arena) {
	if arena.staging.buffer != vk.Buffer(0) {
		gpu_destroy_buffer(ctx, &arena.staging)
	}
	for &buffer in arena.retired_staging {
		gpu_destroy_buffer(ctx, &buffer)
	}
	if arena.retired_staging != nil do delete(arena.retired_staging)
	if arena.pending_buffers != nil do delete(arena.pending_buffers)
	if arena.pending_images != nil do delete(arena.pending_images)
	arena^ = {}
}

gpu_upload_context_init :: proc(ctx: ^Gpu_Context) {
	capacity := ctx.desc.upload_staging_capacity
	if capacity == 0 do capacity = gpu_upload_default_staging_size
	for i in 0..<max_frames_in_flight {
		gpu_upload_arena_init(&ctx.upload.frames[i], capacity)
	}
	gpu_upload_arena_init(&ctx.upload.immediate, capacity)
}

gpu_upload_context_shutdown :: proc(ctx: ^Gpu_Context) {
	for i in 0..<max_frames_in_flight {
		gpu_upload_arena_shutdown(ctx, &ctx.upload.frames[i])
	}
	gpu_upload_arena_shutdown(ctx, &ctx.upload.immediate)
	ctx.upload = {}
}

gpu_upload_active_arena :: proc(ctx: ^Gpu_Context) -> ^Gpu_Upload_Arena {
	if ctx.upload.in_frame {
		return &ctx.upload.frames[ctx.upload.active_slot]
	}
	return &ctx.upload.immediate
}

gpu_upload_reset_arena :: proc(ctx: ^Gpu_Context, arena: ^Gpu_Upload_Arena) {
	for &buffer in arena.retired_staging {
		gpu_destroy_buffer(ctx, &buffer)
	}
	clear(&arena.retired_staging)
	arena.staging_head = 0
	arena.dirty_start = 0
	arena.dirty_end = 0
	arena.dirty = false
	arena.recorded = false
	clear(&arena.pending_buffers)
	clear(&arena.pending_images)
}

gpu_upload_mark_dirty :: proc(arena: ^Gpu_Upload_Arena, offset, size: u64) {
	if size == 0 {
		return
	}
	if !arena.dirty {
		arena.dirty_start = offset
		arena.dirty_end = offset + size
		arena.dirty = true
		return
	}
	arena.dirty_start = min(arena.dirty_start, offset)
	arena.dirty_end = max(arena.dirty_end, offset + size)
}

gpu_upload_begin :: proc(ctx: ^Gpu_Context) {
	ctx.upload.active_slot = u32(ctx.base.CurrentFrame)
	ctx.upload.in_frame = true
	// gpu_prepare_frame waited for this slot's fence, so its staging data is no
	// longer referenced by the device.
	gpu_upload_reset_arena(ctx, &ctx.upload.frames[ctx.upload.active_slot])
}

gpu_upload_end :: proc(ctx: ^Gpu_Context) {
	ctx.upload.in_frame = false
}

gpu_upload_has_pending_arena :: proc(arena: ^Gpu_Upload_Arena) -> bool {
	return len(arena.pending_buffers) > 0 || len(arena.pending_images) > 0
}

gpu_upload_has_pending :: proc(ctx: ^Gpu_Context) -> bool {
	return gpu_upload_has_pending_arena(gpu_upload_active_arena(ctx))
}

gpu_upload_align_up :: proc(value, alignment: u64) -> u64 {
	if alignment <= 1 do return value
	return ((value + alignment - 1) / alignment) * alignment
}

gpu_upload_ensure_staging_capacity :: proc(ctx: ^Gpu_Context, arena: ^Gpu_Upload_Arena, min_required: u64) {
	if min_required <= arena.staging_capacity && arena.staging.buffer != vk.Buffer(0) {
		return
	}

	new_capacity := max(arena.staging_capacity, u64(gpu_upload_default_staging_size))
	for new_capacity < min_required do new_capacity *= 2
	new_staging := gpu_create_buffer(ctx, new_capacity, {.TRANSFER_SRC}, .Upload, "gpu_upload_staging")
	if arena.staging.buffer != vk.Buffer(0) {
		// Pending copies store offsets rather than buffer handles, so moving the
		// bytes preserves the entire queue without submitting or waiting.
		if arena.staging_head > 0 {
			libc.memcpy(new_staging.cpu, arena.staging.cpu, uint(arena.staging_head))
			arena.dirty_start = 0
			arena.dirty_end = arena.staging_head
			arena.dirty = true
		}
		old_staging := arena.staging
		if arena.recorded {
			append(&arena.retired_staging, old_staging)
		} else {
			gpu_destroy_buffer(ctx, &old_staging)
		}
	}
	arena.staging = new_staging
	arena.staging_capacity = new_capacity
}

gpu_upload_alloc_staging :: proc(ctx: ^Gpu_Context, size: u64, alignment: u64 = 4) -> (^Gpu_Upload_Arena, u64) {
	arena := gpu_upload_active_arena(ctx)
	start := gpu_upload_align_up(arena.staging_head, alignment)
	gpu_upload_ensure_staging_capacity(ctx, arena, start + size)
	arena.staging_head = start + size
	return arena, start
}

gpu_upload_enqueue_buffer_copy :: proc(ctx: ^Gpu_Context, dst: vk.Buffer, data: rawptr, size: u64, dst_offset: u64 = 0) {
	if size == 0 do return
	arena, src_offset := gpu_upload_alloc_staging(ctx, size, 4)
	libc.memcpy(rawptr(uintptr(arena.staging.cpu) + uintptr(src_offset)), data, uint(size))
	gpu_upload_mark_dirty(arena, src_offset, size)
	append(&arena.pending_buffers, Gpu_Pending_Buffer_Copy{
		src_offset = src_offset,
		dst = dst,
		dst_offset = dst_offset,
		size = size,
	})
}

gpu_upload_enqueue_texture_copy :: proc(ctx: ^Gpu_Context, texture: Gpu_Texture_Handle, desc: Gpu_Image_Upload_Desc, data: []u8) {
	if len(data) == 0 do return
	arena, src_offset := gpu_upload_alloc_staging(ctx, u64(len(data)), 4)
	libc.memcpy(rawptr(uintptr(arena.staging.cpu) + uintptr(src_offset)), raw_data(data), uint(len(data)))
	gpu_upload_mark_dirty(arena, src_offset, u64(len(data)))
	append(&arena.pending_images, Gpu_Pending_Image_Copy{
		src_offset = src_offset,
		texture = texture,
		region = desc.region,
		final_layout = desc.final_layout,
	})
}

gpu_upload_record_internal :: proc(ctx: ^Gpu_Context, arena: ^Gpu_Upload_Arena, cmd: vk.CommandBuffer) {
	if arena.dirty {
		gpu_flush_buffer(
			&arena.staging,
			arena.dirty_start,
			arena.dirty_end - arena.dirty_start,
		)
	}
	for copy in arena.pending_buffers {
		gpu_copy_buffer(cmd, arena.staging.buffer, copy.dst, copy.size, copy.src_offset, copy.dst_offset)
	}

	touched := make([dynamic]Gpu_Touched_Image, 0, len(arena.pending_images), context.temp_allocator)
	for copy in arena.pending_images {
		slot, _, ok := gpu_texture_slot(ctx, copy.texture)
		if !ok do continue

		touched_index := -1
		for touched_image, index in touched {
			if touched_image.texture == copy.texture {
				touched_index = index
				break
			}
		}
		tex := &slot.tex
		if touched_index < 0 {
			gpu_transition_image_aspect(cmd, tex.image, tex.current_layout, .TRANSFER_DST_OPTIMAL, tex.aspect)
			append(&touched, Gpu_Touched_Image{
				texture = copy.texture,
				final_layout = copy.final_layout,
			})
		} else {
			touched[touched_index].final_layout = copy.final_layout
		}

		region := vk.BufferImageCopy{
			bufferOffset = vk.DeviceSize(copy.src_offset),
			imageSubresource = {
				aspectMask = tex.aspect,
				mipLevel = 0,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			imageOffset = {i32(copy.region.x), i32(copy.region.y), 0},
			imageExtent = {copy.region.width, copy.region.height, 1},
		}
		vk.CmdCopyBufferToImage(cmd, arena.staging.buffer, tex.image, .TRANSFER_DST_OPTIMAL, 1, &region)
	}

	for touched_image in touched {
		slot, _, ok := gpu_texture_slot(ctx, touched_image.texture)
		if !ok do continue
		final_layout := touched_image.final_layout
		if final_layout == vk.ImageLayout(0) do final_layout = .SHADER_READ_ONLY_OPTIMAL
		gpu_transition_image_aspect(cmd, slot.tex.image, .TRANSFER_DST_OPTIMAL, final_layout, slot.tex.aspect)
		slot.tex.current_layout = final_layout
	}
}

gpu_upload_record :: proc(ctx: ^Gpu_Context, cmd: vk.CommandBuffer) {
	arena := gpu_upload_active_arena(ctx)
	if !gpu_upload_has_pending_arena(arena) do return
	gpu_upload_record_internal(ctx, arena, cmd)
	clear(&arena.pending_buffers)
	clear(&arena.pending_images)
	arena.recorded = true
}

gpu_upload_flush :: proc(ctx: ^Gpu_Context) {
	arena := gpu_upload_active_arena(ctx)
	if !gpu_upload_has_pending_arena(arena) do return
	cmd := gpu_immediate_submit_begin(&ctx.base)
	gpu_upload_record_internal(ctx, arena, cmd)
	gpu_immediate_submit_end(&ctx.base, cmd)
	gpu_upload_reset_arena(ctx, arena)
}
