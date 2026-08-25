package gpu

import vma "../odin-vma"
import vk "vendor:vulkan"

Gpu_Deferred_Buffer :: struct {
	buffer:     vk.Buffer,
	allocation: vma.Allocation,
}

Gpu_Deferred_Texture :: struct {
	image:      vk.Image,
	view:       vk.ImageView,
	allocation: vma.Allocation,
	slot_index: u32,
}

Gpu_Deferred_Sampler :: struct {
	sampler:    vk.Sampler,
	slot_index: u32,
}

Gpu_Deferred_Pipeline :: struct {
	pipeline: vk.Pipeline,
	layout:   vk.PipelineLayout,
}

Gpu_Deletion_Queue :: struct {
	buffers:  [dynamic]Gpu_Deferred_Buffer,
	textures: [dynamic]Gpu_Deferred_Texture,
	samplers: [dynamic]Gpu_Deferred_Sampler,
	pipelines: [dynamic]Gpu_Deferred_Pipeline,
}

gpu_deletion_target_slot :: proc(ctx: ^Gpu_Context) -> u32 {
	count := max(u32(1), ctx.base.FrameCount)
	return u32((ctx.base.CurrentFrame + u64(count) - 1) % u64(count))
}

gpu_defer_buffer_destroy :: proc(ctx: ^Gpu_Context, buffer: vk.Buffer, allocation: vma.Allocation) {
	if buffer == vk.Buffer(0) do return
	slot := gpu_deletion_target_slot(ctx)
	append(&ctx.deletions[slot].buffers, Gpu_Deferred_Buffer{buffer = buffer, allocation = allocation})
}

gpu_defer_texture_destroy :: proc(
	ctx: ^Gpu_Context,
	image: vk.Image,
	view: vk.ImageView,
	allocation: vma.Allocation,
	slot_index: u32,
) {
	slot := gpu_deletion_target_slot(ctx)
	append(&ctx.deletions[slot].textures, Gpu_Deferred_Texture{
		image = image,
		view = view,
		allocation = allocation,
		slot_index = slot_index,
	})
}

gpu_defer_sampler_destroy :: proc(ctx: ^Gpu_Context, sampler: vk.Sampler, slot_index: u32) {
	if sampler == vk.Sampler(0) do return
	slot := gpu_deletion_target_slot(ctx)
	append(&ctx.deletions[slot].samplers, Gpu_Deferred_Sampler{sampler = sampler, slot_index = slot_index})
}

gpu_defer_pipeline_destroy :: proc(ctx: ^Gpu_Context, pipeline: vk.Pipeline, layout: vk.PipelineLayout) {
	if pipeline == vk.Pipeline(0) && layout == vk.PipelineLayout(0) do return
	slot := gpu_deletion_target_slot(ctx)
	append(&ctx.deletions[slot].pipelines, Gpu_Deferred_Pipeline{pipeline = pipeline, layout = layout})
}

gpu_collect_deletions :: proc(ctx: ^Gpu_Context, slot: u32) {
	if ctx == nil || slot >= max_frames_in_flight do return
	queue := &ctx.deletions[slot]
	for item in queue.buffers {
		vma.DestroyBuffer(ctx.base.GPUAllocator, item.buffer, item.allocation)
	}
	for item in queue.textures {
		if item.view != vk.ImageView(0) {
			vk.DestroyImageView(ctx.base.Device.LogicalDevice, item.view, nil)
		}
		if item.image != vk.Image(0) {
			vma.DestroyImage(ctx.base.GPUAllocator, item.image, item.allocation)
		}
		append(&ctx.bindless.free_texture_indices, item.slot_index)
	}
	for item in queue.samplers {
		vk.DestroySampler(ctx.base.Device.LogicalDevice, item.sampler, nil)
		append(&ctx.bindless.free_sampler_indices, item.slot_index)
	}
	for item in queue.pipelines {
		if item.pipeline != vk.Pipeline(0) {
			vk.DestroyPipeline(ctx.base.Device.LogicalDevice, item.pipeline, nil)
		}
		if item.layout != vk.PipelineLayout(0) {
			vk.DestroyPipelineLayout(ctx.base.Device.LogicalDevice, item.layout, nil)
		}
	}
	clear(&queue.buffers)
	clear(&queue.textures)
	clear(&queue.samplers)
	clear(&queue.pipelines)
}

gpu_deletion_queues_shutdown :: proc(ctx: ^Gpu_Context) {
	for slot in 0..<max_frames_in_flight {
		gpu_collect_deletions(ctx, u32(slot))
		queue := &ctx.deletions[slot]
		if queue.buffers != nil do delete(queue.buffers)
		if queue.textures != nil do delete(queue.textures)
		if queue.samplers != nil do delete(queue.samplers)
		if queue.pipelines != nil do delete(queue.pipelines)
		queue^ = {}
	}
}
