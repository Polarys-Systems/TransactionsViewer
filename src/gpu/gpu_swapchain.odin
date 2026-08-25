package gpu

// Swapchain lifecycle and window-size dependent image resources.

import "core:math/bits"
import vk "vendor:vulkan"

Gpu_Swapchain_Desc :: struct {
	preferred_formats: []vk.Format,
	preferred_color_spaces: []vk.ColorSpaceKHR,
	preferred_present_modes: []vk.PresentModeKHR,

	image_usage: vk.ImageUsageFlags,
	min_image_count: u32,
	composite_alpha: vk.CompositeAlphaFlagsKHR,
	clipped: bool,
}

default_swapchain_formats := [?]vk.Format{.B8G8R8A8_UNORM}
default_swapchain_color_spaces := [?]vk.ColorSpaceKHR{.SRGB_NONLINEAR}
default_swapchain_present_modes := [?]vk.PresentModeKHR{.FIFO}

gpu_swapchain_desc_default :: proc() -> Gpu_Swapchain_Desc {
	return Gpu_Swapchain_Desc{
		preferred_formats = default_swapchain_formats[:],
		preferred_color_spaces = default_swapchain_color_spaces[:],
		preferred_present_modes = default_swapchain_present_modes[:],
		image_usage = {.COLOR_ATTACHMENT, .TRANSFER_DST},
		min_image_count = 0,
		composite_alpha = {.OPAQUE},
		clipped = true,
	}
}

destroy_swapchain_resources :: proc(base: ^Vulkan_Base, swapchain: ^Vk_Swapchain, allocator := context.allocator) {
	if swapchain == nil {
		return
	}
	if base.Device.LogicalDevice != nil {
		for i in 0..<swapchain.N_ImageViews {
			if swapchain.ImageViews[i] != 0 {
				vk.DestroyImageView(base.Device.LogicalDevice, swapchain.ImageViews[i], nil)
			}
		}
		if swapchain.Swapchain != 0 {
			vk.DestroySwapchainKHR(base.Device.LogicalDevice, swapchain.Swapchain, nil)
		}
	}
	if swapchain.ImageViews != nil {
		free(swapchain.ImageViews, allocator)
	}
	if swapchain.Images != nil {
		free(swapchain.Images, allocator)
	}
	if swapchain.Layouts != nil {
		free(swapchain.Layouts, allocator)
	}
	swapchain^ = {}
}

commit_swapchain_replacement :: proc(base: ^Vulkan_Base, next: ^Vk_Swapchain, pixel_extent: vk.Extent2D, allocator := context.allocator) {
	old := base.Swapchain
	base.Swapchain = next^
	next^ = {}
	base.SwapchainGeneration += 1
	base.Window.last_extent = pixel_extent
	destroy_swapchain_resources(base, &old, allocator)
}

choose_surface_format :: proc(support: Swapchain_Support_Details, desc: Gpu_Swapchain_Desc) -> vk.SurfaceFormatKHR {
	if len(support.Formats) == 1 && support.Formats[0].format == .UNDEFINED {
		return vk.SurfaceFormatKHR{desc.preferred_formats[0], desc.preferred_color_spaces[0]}
	}
	for preferred_format in desc.preferred_formats {
		for preferred_color in desc.preferred_color_spaces {
			for available in support.Formats {
				if available.format == preferred_format && available.colorSpace == preferred_color {
					return available
				}
			}
		}
	}
	return support.Formats[0]
}

choose_present_mode :: proc(support: Swapchain_Support_Details, desc: Gpu_Swapchain_Desc) -> vk.PresentModeKHR {
	for preferred in desc.preferred_present_modes {
		for available in support.PresentModes {
			if available == preferred do return available
		}
	}
	return .FIFO
}

choose_composite_alpha :: proc(requested, supported: vk.CompositeAlphaFlagsKHR) -> (vk.CompositeAlphaFlagsKHR, bool) {
	if requested != {} {
		count := 0
		for alpha in requested {
			if alpha not_in supported do return {}, false
			count += 1
		}
		return requested, count == 1
	}

	preference := [?]vk.CompositeAlphaFlagKHR{.OPAQUE, .PRE_MULTIPLIED, .POST_MULTIPLIED, .INHERIT}
	for alpha in preference {
		if alpha in supported do return {alpha}, true
	}
	return {}, false
}

create_swapchain_with_desc :: proc(base: ^Vulkan_Base, desc: Gpu_Swapchain_Desc, allocator := context.allocator) -> Gpu_Error {
	if base == nil || base.Device.LogicalDevice == nil || base.Window.surface == 0 {
		return gpu_error(.Invalid_Argument, "Cannot create swapchain without a device and SDL surface")
	}

	resolved := desc
	pixel_extent := gpu_window_state_extent(&base.Window)
	if len(resolved.preferred_formats) == 0 do resolved.preferred_formats = default_swapchain_formats[:]
	if len(resolved.preferred_color_spaces) == 0 do resolved.preferred_color_spaces = default_swapchain_color_spaces[:]
	if len(resolved.preferred_present_modes) == 0 do resolved.preferred_present_modes = default_swapchain_present_modes[:]
	if resolved.image_usage == {} do resolved.image_usage = {.COLOR_ATTACHMENT, .TRANSFER_DST}

	support, support_result := query_swapchain_support(base, base.Device.PhysicalDevice, context.temp_allocator)
	defer destroy_swapchain_support_details(&support, context.temp_allocator)
	if support_result != .SUCCESS {
		return gpu_error(.Vulkan_Error, "Failed to query swapchain surface support", support_result)
	}
	imageCount := support.Capabilities.minImageCount + 1
	if resolved.min_image_count > 0 {
		imageCount = max(imageCount, resolved.min_image_count)
	}

	if len(support.Formats) == 0 {
		return gpu_error(.Unsupported_Feature, "No swapchain surface formats reported")
	}
	if len(support.PresentModes) == 0 {
		return gpu_error(.Unsupported_Feature, "No swapchain present modes reported")
	}

	if (resolved.image_usage & support.Capabilities.supportedUsageFlags) != resolved.image_usage {
		return gpu_error(.Unsupported_Feature, "Requested swapchain image usage is not supported by the surface")
	}
	composite_alpha, composite_alpha_ok := choose_composite_alpha(resolved.composite_alpha, support.Capabilities.supportedCompositeAlpha)
	if !composite_alpha_ok {
		return gpu_error(.Unsupported_Feature, "Requested swapchain composite alpha is invalid or unsupported")
	}

	surface_format := choose_surface_format(support, resolved)
	present_mode := choose_present_mode(support, resolved)

	extent := pixel_extent
	if support.Capabilities.currentExtent.width != bits.U32_MAX {
		extent = support.Capabilities.currentExtent
	} else {
		extent.width = clamp(extent.width, support.Capabilities.minImageExtent.width, support.Capabilities.maxImageExtent.width)
		extent.height = clamp(extent.height, support.Capabilities.minImageExtent.height, support.Capabilities.maxImageExtent.height)
	}
	if extent.width == 0 || extent.height == 0 {
		return gpu_error(.Not_Ready, "Cannot create a swapchain for a zero-sized window")
	}

	if support.Capabilities.maxImageCount > 0 && imageCount > support.Capabilities.maxImageCount {
		imageCount = support.Capabilities.maxImageCount
	}

	create_info := vk.SwapchainCreateInfoKHR{
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = base.Window.surface,
		minImageCount    = imageCount,
		imageFormat      = surface_format.format,
		imageColorSpace  = surface_format.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = resolved.image_usage,
		preTransform     = support.Capabilities.currentTransform,
		compositeAlpha   = composite_alpha,
		presentMode      = present_mode,
		clipped          = auto_cast resolved.clipped,
		oldSwapchain     = base.Swapchain.Swapchain,
	}

	indices := base.Device.FamilyIndices
	qFamilyIndices := [?]u32{indices.Graphics, indices.Presentation}

	if indices.Graphics != indices.Presentation {
		create_info.imageSharingMode = .CONCURRENT
		create_info.queueFamilyIndexCount = 2
		create_info.pQueueFamilyIndices = &qFamilyIndices[0]
	} else {
		create_info.imageSharingMode = .EXCLUSIVE
	}

	next: Vk_Swapchain
	result := vk.CreateSwapchainKHR(base.Device.LogicalDevice, &create_info, nil, &next.Swapchain)
	if result != .SUCCESS {
		return gpu_error(.Vulkan_Error, "Failed to create swapchain", result)
	}
	result = vk.GetSwapchainImagesKHR(base.Device.LogicalDevice, next.Swapchain, &next.N_Images, nil)
	if result != .SUCCESS {
		// A successful vkCreateSwapchainKHR retires oldSwapchain. Keep the new
		// handle current so a later retry never attempts to reuse the retired one.
		commit_swapchain_replacement(base, &next, pixel_extent, allocator)
		return gpu_error(.Vulkan_Error, "Failed to query swapchain images", result)
	}
	if next.N_Images == 0 {
		commit_swapchain_replacement(base, &next, pixel_extent, allocator)
		return gpu_error(.Unsupported_Feature, "Swapchain reported no images")
	}
	next.Images = make([^]vk.Image, next.N_Images, allocator)
	next.Layouts = make([^]vk.ImageLayout, next.N_Images, allocator)
	result = vk.GetSwapchainImagesKHR(base.Device.LogicalDevice, next.Swapchain, &next.N_Images, next.Images)
	if result != .SUCCESS {
		commit_swapchain_replacement(base, &next, pixel_extent, allocator)
		return gpu_error(.Vulkan_Error, "Failed to retrieve swapchain images", result)
	}

	next.Format = surface_format.format
	next.Extent = extent
	next.Capabilities = support.Capabilities
	err := create_image_views(base, &next, allocator)
	if !gpu_error_is_ok(err) {
		commit_swapchain_replacement(base, &next, pixel_extent, allocator)
		return err
	}

	commit_swapchain_replacement(base, &next, pixel_extent, allocator)
	return gpu_error_ok()
}

create_swapchain :: proc(base: ^Vulkan_Base, allocator := context.allocator) -> Gpu_Error {
	desc := base.InitDesc.swapchain
	return create_swapchain_with_desc(base, desc, allocator)
}
