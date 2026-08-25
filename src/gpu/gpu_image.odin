package gpu

import vk "vendor:vulkan"

create_image_views :: proc(base: ^Vulkan_Base, swapchain: ^Vk_Swapchain, allocator := context.allocator) -> Gpu_Error {
	swapchain.N_ImageViews = swapchain.N_Images
	swapchain.ImageViews = make([^]vk.ImageView, swapchain.N_ImageViews, allocator)

	for i in 0..<swapchain.N_ImageViews {
		create_info := vk.ImageViewCreateInfo{
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = swapchain.Images[i],
			viewType = .D2,
			format = swapchain.Format,
			components = {.IDENTITY, .IDENTITY, .IDENTITY, .IDENTITY},
			subresourceRange = {
				aspectMask = {.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}
		result := vk.CreateImageView(base.Device.LogicalDevice, &create_info, nil, &swapchain.ImageViews[i])
		if result != .SUCCESS {
			return gpu_error(.Vulkan_Error, "Failed to create swapchain image view", result)
		}
	}
	return gpu_error_ok()
}
