package gpu

import "core:c/libc"

import vma "../odin-vma"
import vk "vendor:vulkan"

/*
Smart buffer creation with memory-policy selection and optional BDA address.

Example:
	vertex_buffer := gpu_create_buffer(
		ctx,
		1024 * 1024,
		{.VERTEX_BUFFER, .TRANSFER_DST},
		.Device,
		"mesh_vertices",
	)
*/

Gpu_Buffer :: struct {
	buffer:      vk.Buffer,
	allocation:  vma.Allocation,
	allocator:   vma.Allocator,
	alloc_info:  vma.AllocationInfo,
	size:        u64,

	cpu: rawptr,
	gpu: vk.DeviceAddress,

	usage:       vk.BufferUsageFlags,
	memory_kind: Gpu_Memory_Kind,
}

gpu_resolve_memory_kind :: proc(ctx: ^Gpu_Context, size: u64, usage: vk.BufferUsageFlags, requested: Gpu_Memory_Kind) -> Gpu_Memory_Kind {
	if requested != .Auto {
		return requested
	}

	is_dynamic := (.UNIFORM_BUFFER in usage) || (.STORAGE_BUFFER in usage) || (.VERTEX_BUFFER in usage) || (.INDEX_BUFFER in usage)
	// Dynamic data prefers CPU-visible memory when a host-visible device-local heap exists.
	if is_dynamic && size <= 4 * 1024 * 1024 && ctx.capabilities.host_visible_device_local_memory {
		return .Upload
	}

	if (.TRANSFER_DST in usage) {
		return .Device
	}

	if size <= 256 * 1024 {
		return .Upload
	}

	return .Device
}

gpu_get_device_address :: proc(ctx: ^Gpu_Context, buffer: vk.Buffer) -> vk.DeviceAddress {
	info := vk.BufferDeviceAddressInfo{
		sType  = .BUFFER_DEVICE_ADDRESS_INFO,
		pNext  = nil,
		buffer = buffer,
	}
	return vk.GetBufferDeviceAddress(ctx.base.Device.LogicalDevice, &info)
}

gpu_buffer_address :: proc(buffer: ^Gpu_Buffer) -> vk.DeviceAddress {
	if buffer == nil do return 0
	return buffer.gpu
}

gpu_create_buffer :: proc(
	ctx: ^Gpu_Context,
	size: u64,
	usage: vk.BufferUsageFlags,
	kind := Gpu_Memory_Kind.Auto,
	name := "",
) -> Gpu_Buffer {
	_ = name

	resolved := gpu_resolve_memory_kind(ctx, size, usage, kind)
	final_usage := usage
	needs_device_address := (.STORAGE_BUFFER in final_usage) || (.VERTEX_BUFFER in final_usage) || (.INDEX_BUFFER in final_usage)
	if needs_device_address && resolved != .Readback {
		final_usage += {.SHADER_DEVICE_ADDRESS}
	}

	buffer_info := vk.BufferCreateInfo{
		sType = .BUFFER_CREATE_INFO,
		pNext = nil,
		size  = vk.DeviceSize(size),
		usage = final_usage,
	}

	alloc_info: vma.AllocationCreateInfo
	mapped := false

	switch resolved {
	case .Upload, .Transient_Frame:
		alloc_info.usage = .CPU_TO_GPU
		alloc_info.flags = {vma.AllocationCreateFlagBit.MAPPED, vma.AllocationCreateFlagBit.HOST_ACCESS_SEQUENTIAL_WRITE}
		mapped = true
	case .Readback:
		alloc_info.usage = .GPU_TO_CPU
		alloc_info.flags = {vma.AllocationCreateFlagBit.MAPPED, vma.AllocationCreateFlagBit.HOST_ACCESS_RANDOM}
		mapped = true
	case .Device:
		alloc_info.usage = .GPU_ONLY
		alloc_info.flags = {}
	case .Auto:
		alloc_info.usage = .AUTO
		alloc_info.flags = {}
	}

	out: Gpu_Buffer
	out.size = size
	out.allocator = ctx.base.GPUAllocator
	out.usage = final_usage
	out.memory_kind = resolved

	vk_check(vma.CreateBuffer(ctx.base.GPUAllocator, &buffer_info, &alloc_info, &out.buffer, &out.allocation, &out.alloc_info))

	if mapped {
		out.cpu = out.alloc_info.pMappedData
	}

	if .SHADER_DEVICE_ADDRESS in out.usage {
		out.gpu = gpu_get_device_address(ctx, out.buffer)
	}

	return out
}

gpu_flush_buffer :: proc(buffer: ^Gpu_Buffer, offset: u64 = 0, size: u64 = 0) {
	if buffer == nil || buffer.cpu == nil || buffer.allocation == nil || buffer.allocator == nil {
		return
	}
	flush_size := size
	if flush_size == 0 {
		flush_size = buffer.size - min(offset, buffer.size)
	}
	if flush_size == 0 {
		return
	}
	vk_check(vma.FlushAllocation(
		buffer.allocator,
		buffer.allocation,
		vk.DeviceSize(offset),
		vk.DeviceSize(flush_size),
	))
}

gpu_destroy_buffer :: proc(ctx: ^Gpu_Context, buffer: ^Gpu_Buffer) {
	if buffer == nil {
		return
	}
	if buffer.buffer != vk.Buffer(0) {
		gpu_defer_buffer_destroy(ctx, buffer.buffer, buffer.allocation)
	}
	buffer^ = {}
}

gpu_upload_buffer :: proc(ctx: ^Gpu_Context, dst: ^Gpu_Buffer, data: rawptr, size: u64, dst_offset: u64 = 0) {
	assert(dst != nil)
	assert(size + dst_offset <= dst.size)

	if dst.cpu != nil {
		libc.memcpy(rawptr(uintptr(dst.cpu) + uintptr(dst_offset)), data, uint(size))
		gpu_flush_buffer(dst, dst_offset, size)
		return
	}

	gpu_upload_enqueue_buffer_copy(ctx, dst.buffer, data, size, dst_offset)
	gpu_upload_flush(ctx)
}
