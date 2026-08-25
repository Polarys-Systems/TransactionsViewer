package gpu

import vk "vendor:vulkan"

// Vulkan 1.3 synchronization2 and dynamic-rendering helpers.

gpu_transition_image :: proc(cmd: vk.CommandBuffer, image: vk.Image, old_layout, new_layout: vk.ImageLayout) {
	transition_image(cmd, image, old_layout, new_layout)
}

gpu_transition_image_aspect :: proc(
	cmd: vk.CommandBuffer,
	image: vk.Image,
	old_layout, new_layout: vk.ImageLayout,
	aspect: vk.ImageAspectFlags,
) {
	transition_image(cmd, image, old_layout, new_layout, aspect)
}

Gpu_Rendering_Attachment :: struct {
	view:       vk.ImageView,
	layout:     vk.ImageLayout,
	load_op:    vk.AttachmentLoadOp,
	store_op:   vk.AttachmentStoreOp,
	clear:      vk.ClearValue,
}

Gpu_Rendering_Desc :: struct {
	render_area: vk.Rect2D,
	layer_count: u32,
	colors:      []Gpu_Rendering_Attachment,
	depth:       ^Gpu_Rendering_Attachment,
	stencil:     ^Gpu_Rendering_Attachment,
}

gpu_rendering_attachment_info :: proc(desc: Gpu_Rendering_Attachment) -> vk.RenderingAttachmentInfo {
	return vk.RenderingAttachmentInfo{
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = desc.view,
		imageLayout = desc.layout,
		loadOp      = desc.load_op,
		storeOp     = desc.store_op,
		clearValue  = desc.clear,
	}
}

gpu_begin_rendering :: proc(cmd: vk.CommandBuffer, desc: Gpu_Rendering_Desc) {
	colors := make([]vk.RenderingAttachmentInfo, len(desc.colors), context.temp_allocator)
	for attachment, i in desc.colors {
		colors[i] = gpu_rendering_attachment_info(attachment)
	}
	depth_info, stencil_info: vk.RenderingAttachmentInfo
	depth_ptr, stencil_ptr: ^vk.RenderingAttachmentInfo
	if desc.depth != nil {
		depth_info = gpu_rendering_attachment_info(desc.depth^)
		depth_ptr = &depth_info
	}
	if desc.stencil != nil {
		stencil_info = gpu_rendering_attachment_info(desc.stencil^)
		stencil_ptr = &stencil_info
	}
	layers := desc.layer_count
	if layers == 0 do layers = 1
	info := vk.RenderingInfo{
		sType = .RENDERING_INFO,
		renderArea = desc.render_area,
		layerCount = layers,
		colorAttachmentCount = u32(len(colors)),
		pColorAttachments = raw_data(colors),
		pDepthAttachment = depth_ptr,
		pStencilAttachment = stencil_ptr,
	}
	vk.CmdBeginRendering(cmd, &info)
}

gpu_end_rendering :: proc(cmd: vk.CommandBuffer) {
	vk.CmdEndRendering(cmd)
}

Gpu_Swapchain_Rendering_Desc :: struct {
	clear: bool,
	color: [4]f32,
}

gpu_begin_swapchain_rendering :: proc(ctx: ^Gpu_Context, frame: Gpu_Frame, desc: Gpu_Swapchain_Rendering_Desc) {
	old_layout := ctx.base.Swapchain.Layouts[frame.swapchain_image]
	gpu_transition_image(frame.cmd, frame.image, old_layout, .COLOR_ATTACHMENT_OPTIMAL)
	ctx.base.Swapchain.Layouts[frame.swapchain_image] = .COLOR_ATTACHMENT_OPTIMAL
	clear_color: vk.ClearColorValue
	clear_color.float32 = desc.color
	clear_value := vk.ClearValue{color = clear_color}
	load_op := vk.AttachmentLoadOp.LOAD
	if desc.clear do load_op = .CLEAR
	if !desc.clear && old_layout == .UNDEFINED do load_op = .DONT_CARE
	attachment := [1]Gpu_Rendering_Attachment{{
		view = frame.view,
		layout = .COLOR_ATTACHMENT_OPTIMAL,
		load_op = load_op,
		store_op = .STORE,
		clear = clear_value,
	}}
	gpu_begin_rendering(frame.cmd, {
		render_area = {{0, 0}, frame.extent},
		colors = attachment[:],
	})
}

gpu_end_swapchain_rendering :: proc(ctx: ^Gpu_Context, frame: Gpu_Frame) {
	gpu_end_rendering(frame.cmd)
	gpu_transition_image(frame.cmd, frame.image, .COLOR_ATTACHMENT_OPTIMAL, .PRESENT_SRC_KHR)
	ctx.base.Swapchain.Layouts[frame.swapchain_image] = .PRESENT_SRC_KHR
}

gpu_copy_buffer :: proc(cmd: vk.CommandBuffer, src, dst: vk.Buffer, size: u64, src_offset: u64 = 0, dst_offset: u64 = 0) {
	region := vk.BufferCopy{
		srcOffset = vk.DeviceSize(src_offset),
		dstOffset = vk.DeviceSize(dst_offset),
		size      = vk.DeviceSize(size),
	}
	vk.CmdCopyBuffer(cmd, src, dst, 1, &region)
}

gpu_blit_image :: proc(
	cmd: vk.CommandBuffer,
	source: vk.Image,
	destination: vk.Image,
	src_size: vk.Extent2D,
	dst_size: vk.Extent2D,
) {
	copy_image_to_image(cmd, source, destination, src_size, dst_size)
}
