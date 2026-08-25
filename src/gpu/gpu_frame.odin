package gpu

import "core:mem"
import vk "vendor:vulkan"

/*
Per-frame bump allocator for transient root/draw data.

Example:
	tmp := gpu_frame_alloc(ctx, frame, size_of(My_Draw_Data), align_of(My_Draw_Data))
	data := (^My_Draw_Data)(tmp.cpu)
	data^ = my_draw_data
*/

frame_allocator_capacity :: u64(8 * 1024 * 1024)

Gpu_Frame_Allocator :: struct {
	buffer:   Gpu_Buffer,
	offset:   u64,
	capacity: u64,
}

gpu_frame_allocator_init :: proc(ctx: ^Gpu_Context, alloc: ^Gpu_Frame_Allocator, capacity: u64 = frame_allocator_capacity) {
	alloc^ = {}
	alloc.capacity = capacity
	alloc.buffer = gpu_create_buffer(
		ctx,
		capacity,
		{.STORAGE_BUFFER, .TRANSFER_SRC, .TRANSFER_DST},
		.Transient_Frame,
		"frame_allocator",
	)
}

gpu_frame_allocator_shutdown :: proc(ctx: ^Gpu_Context, alloc: ^Gpu_Frame_Allocator) {
	gpu_destroy_buffer(ctx, &alloc.buffer)
	alloc.offset = 0
	alloc.capacity = 0
}

gpu_frame_allocator_reset :: proc(alloc: ^Gpu_Frame_Allocator) {
	alloc.offset = 0
}

gpu_frame_alloc :: proc(ctx: ^Gpu_Context, frame: Gpu_Frame, size: u64, alignment: u64 = 16) -> Gpu_Temp_Allocation {
	_ = frame
	frame_slot := frame.frame_slot % u64(max(1, ctx.base.FrameCount))
	alloc := &ctx.frame_allocators[frame_slot]

	// Align each allocation to keep GPU-side struct accesses valid.
	base_offset := align_up_u64(alloc.offset, alignment)
	end_offset := base_offset + size
	if end_offset > alloc.capacity {
		panic("[GPU] Frame allocator exhausted")
	}

	out := Gpu_Temp_Allocation{
		cpu  = rawptr(uintptr(alloc.buffer.cpu) + uintptr(base_offset)),
		gpu  = alloc.buffer.gpu + vk.DeviceAddress(base_offset),
		size = size,
	}

	alloc.offset = end_offset
	return out
}

gpu_frame_alloc_typed :: proc($T: typeid, ctx: ^Gpu_Context, frame: Gpu_Frame) -> Gpu_Temp_Typed(T) {
	size := u64(mem.size_of(T))
	alignment := u64(mem.align_of(T))
	tmp := gpu_frame_alloc(ctx, frame, size, alignment)
	return Gpu_Temp_Typed(T){
		cpu  = (^T)(tmp.cpu),
		gpu  = tmp.gpu,
		size = tmp.size,
	}
}
