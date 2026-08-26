package gpu 

// Low-level Vulkan 1.3 device/bootstrap internals.

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:math/bits"
import "core:strings"

import vma "../odin-vma"

import SDL "vendor:sdl3"
import vk "vendor:vulkan" 

validation_layers := [?]cstring{ "VK_LAYER_KHRONOS_validation" };
vk_check :: proc( x : vk.Result, funct := #caller_location, f := #file, l := #line ) {
	err := x;

	if err != vk.Result.SUCCESS {
		fmt.println(err, funct, f, l);
		panic("[ERROR] Detected vulkan error", funct);
	}
}

cstring_equal :: proc(a, b: cstring) -> bool {
	return libc.strcmp(a, b) == 0
}

gpu_log :: proc(base: ^Vulkan_Base, level: Gpu_Log_Level, message: string) {
	if base != nil && base.LogCallback != nil {
		base.LogCallback(level, message, base.LogUserData)
		return
	}
	gpu_log_fallback(level, message, nil)
}

gpu_error :: proc(result: Gpu_Result, message: string, vk_result: vk.Result = .SUCCESS) -> Gpu_Error {
	return Gpu_Error{
		result    = result,
		vk_result = vk_result,
		message   = message,
	}
}

max_frames_in_flight :: 2

// -----------------------------------------------------------------------------

Queue_Family_Indices :: struct {
	Graphics:     u32,
	Presentation: u32,
}

// -----------------------------------------------------------------------------

Swapchain_Support_Details :: struct {
    Capabilities    :  vk.SurfaceCapabilitiesKHR,
    Formats         : []vk.SurfaceFormatKHR,
    PresentModes    : []vk.PresentModeKHR,
    FormatCount     : u32,
    PresentModeCount: u32,
}

// -----------------------------------------------------------------------------

find_queue_families :: proc(
	v_interface: ^Vulkan_Base,
	device: vk.PhysicalDevice,
) -> Queue_Family_Indices {
	indices := Queue_Family_Indices{bits.U32_MAX, bits.U32_MAX}

	queue_family_count: u32 = 0
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)

	queue_families := make([]vk.QueueFamilyProperties, queue_family_count)
	defer delete_slice(queue_families)

	vk.GetPhysicalDeviceQueueFamilyProperties(
		device,
		&queue_family_count,
		raw_data(queue_families),
	)

	// Prefer a single family for graphics and presentation. This avoids
	// ownership transfers and is the common desktop path.
	for family, i in queue_families {
		if family.queueCount == 0 || .GRAPHICS not_in family.queueFlags {
			continue
		}
		present_support: b32
		if vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), v_interface.Window.surface, &present_support) == .SUCCESS && present_support {
			return Queue_Family_Indices{u32(i), u32(i)}
		}
	}

	for family, i in queue_families {
		if family.queueCount > 0 && .GRAPHICS in family.queueFlags && indices.Graphics == bits.U32_MAX {
			indices.Graphics = u32(i)
		}
		if family.queueCount > 0 && indices.Presentation == bits.U32_MAX {
			present_support: b32
			if vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), v_interface.Window.surface, &present_support) == .SUCCESS && present_support {
				indices.Presentation = u32(i)
			}
		}
	}

	return indices
}

// -----------------------------------------------------------------------------

check_validation_layer_support :: proc(vapp: ^Vulkan_Base) -> bool {
	layer_count: u32
	if vk.EnumerateInstanceLayerProperties(&layer_count, nil) != .SUCCESS {
		gpu_log(vapp, .Error, "Failed to enumerate Vulkan instance layers")
		return false
	}

	available_layers := make([]vk.LayerProperties, layer_count, context.temp_allocator)
	if vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(available_layers)) != .SUCCESS {
		gpu_log(vapp, .Error, "Failed to enumerate Vulkan instance layers")
		return false
	}

	outer: for name in validation_layers {
		for i in 0 ..< layer_count {
			if cstring_equal(cstring(&available_layers[i].layerName[0]), cstring(name)) do continue outer
		}
		gpu_log(vapp, .Error, "Requested Vulkan validation layer is unavailable")
		return false
	}

	return true
}

// -----------------------------------------------------------------------------

check_device_extension_support :: proc(device: vk.PhysicalDevice, extensions: []cstring, allocator := context.allocator) -> bool {
	extension_count: u32
	if vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, nil) != .SUCCESS {
		return false
	}

	available_extension := make(
		[]vk.ExtensionProperties,
		extension_count,
		allocator,
	)

	if vk.EnumerateDeviceExtensionProperties(
		device,
		nil,
		&extension_count,
		raw_data(available_extension),
	) != .SUCCESS {
		delete_slice(available_extension, allocator)
		return false
	}

	for extension in extensions {
		ext_found := false
		for i in 0 ..< extension_count {
			if cstring_equal(cstring(&available_extension[i].extensionName[0]), cstring(extension)) {
				ext_found = true
				break
			}
		}
		if !ext_found {
			delete_slice(available_extension, allocator)
			return false
		}
	}

	delete_slice(available_extension, allocator)
	return true
}

extension_name_in_list :: proc(extensions: []cstring, name: cstring) -> bool {
	for extension in extensions {
		if cstring_equal(extension, name) do return true
	}
	return false
}

append_unique_extension :: proc(extensions: ^[dynamic]cstring, name: cstring) {
	if !extension_name_in_list(extensions[:], name) {
		append(extensions, name)
	}
}

// These capabilities are mandatory core features at our Vulkan 1.3 floor.
// Enabling their historical extension names can reject conformant 1.3 drivers
// which no longer advertise the promoted aliases.
is_promoted_device_extension :: proc(name: cstring) -> bool {
	return cstring_equal(name, "VK_KHR_dynamic_rendering") ||
	       cstring_equal(name, "VK_KHR_synchronization2") ||
	       cstring_equal(name, "VK_KHR_buffer_device_address") ||
	       cstring_equal(name, "VK_EXT_descriptor_indexing")
}

build_required_device_extensions :: proc(desc: Gpu_Desc, allocator := context.allocator) -> [dynamic]cstring {
	extensions := make([dynamic]cstring, 0, len(desc.required_device_extensions)+1, allocator)
	append_unique_extension(&extensions, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
	for extension in desc.required_device_extensions {
		if !is_promoted_device_extension(extension) {
			append_unique_extension(&extensions, extension)
		}
	}
	return extensions
}

// -----------------------------------------------------------------------------

query_swapchain_support :: proc(
	v_interface: ^Vulkan_Base,
	device: vk.PhysicalDevice,
	allocator := context.allocator,
) -> (Swapchain_Support_Details, vk.Result)
{
	details: Swapchain_Support_Details
	result := vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
		device,
		v_interface.Window.surface,
		&details.Capabilities,
	)
	if result != .SUCCESS do return details, result
	result = vk.GetPhysicalDeviceSurfaceFormatsKHR(
		device,
		v_interface.Window.surface,
		&details.FormatCount,
		nil,
	)
	if result != .SUCCESS do return details, result

	if details.FormatCount != 0 {
		details.Formats = make([]vk.SurfaceFormatKHR, details.FormatCount, allocator)
		result = vk.GetPhysicalDeviceSurfaceFormatsKHR(
			device,
			v_interface.Window.surface,
			&details.FormatCount,
			raw_data(details.Formats),
		)
		if result != .SUCCESS do return details, result
	}

	result = vk.GetPhysicalDeviceSurfacePresentModesKHR(
		device,
		v_interface.Window.surface,
		&details.PresentModeCount,
		nil,
	)
	if result != .SUCCESS do return details, result

	if details.PresentModeCount != 0 {
		details.PresentModes = make(
			[]vk.PresentModeKHR,
			details.PresentModeCount,
			allocator,
		)
		result = vk.GetPhysicalDeviceSurfacePresentModesKHR(
			device,
			v_interface.Window.surface,
			&details.PresentModeCount,
			raw_data(details.PresentModes),
		)
		if result != .SUCCESS do return details, result
	}

	return details, .SUCCESS
}

destroy_swapchain_support_details :: proc(details: ^Swapchain_Support_Details, allocator := context.allocator) {
	if details.Formats != nil do delete_slice(details.Formats, allocator)
	if details.PresentModes != nil do delete_slice(details.PresentModes, allocator)
	details^ = {}
}

// -----------------------------------------------------------------------------

has_required_device_features :: proc(device: vk.PhysicalDevice) -> bool {
	features13 := vk.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES}
	features12 := vk.PhysicalDeviceVulkan12Features{
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext = &features13,
	}
	features := vk.PhysicalDeviceFeatures2{
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &features12,
	}
	vk.GetPhysicalDeviceFeatures2(device, &features)

	return features13.dynamicRendering != false &&
	       features13.synchronization2 != false &&
	       features12.bufferDeviceAddress != false &&
	       features12.descriptorIndexing != false &&
	       features12.shaderUniformBufferArrayNonUniformIndexing != false &&
	       features12.shaderSampledImageArrayNonUniformIndexing != false &&
	       features12.descriptorBindingUniformBufferUpdateAfterBind != false &&
	       features12.descriptorBindingSampledImageUpdateAfterBind != false &&
	       features12.descriptorBindingUpdateUnusedWhilePending != false &&
	       features12.descriptorBindingPartiallyBound != false &&
	       features12.runtimeDescriptorArray != false
}

is_suitable_device :: proc(v_interface: ^Vulkan_Base, device: vk.PhysicalDevice, required_extensions: []cstring) -> bool {
	if v_interface.InitDesc.device_filter != nil && !v_interface.InitDesc.device_filter(device, v_interface.InitDesc.device_user_data) {
		return false
	}
	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(device, &properties)
	if properties.apiVersion < vk.API_VERSION_1_3 {
		return false
	}

	indices := find_queue_families(v_interface, device)
	if indices.Graphics == bits.U32_MAX || indices.Presentation == bits.U32_MAX {
		return false
	}
	if !check_device_extension_support(device, required_extensions, context.temp_allocator) {
		return false
	}

	swapchain_support, support_result := query_swapchain_support(v_interface, device, context.temp_allocator)
	defer destroy_swapchain_support_details(&swapchain_support, context.temp_allocator)
	if support_result != .SUCCESS {
		return false
	}
	if len(swapchain_support.Formats) == 0 || len(swapchain_support.PresentModes) == 0 {
		return false
	}
	if !has_required_device_features(device) {
		return false
	}
	return true
}

// -----------------------------------------------------------------------------

Vk_Device :: struct {
    PhysicalDevice    : vk.PhysicalDevice,
    LogicalDevice     : vk.Device,
    GraphicsQueue     : vk.Queue,
    PresentationQueue : vk.Queue,
    FamilyIndices     : Queue_Family_Indices,
}

// -----------------------------------------------------------------------------

Vk_Swapchain :: struct {
    Swapchain: vk.SwapchainKHR,
    Images: [^]vk.Image,
    N_Images: u32,
    ImageViews: [^]vk.ImageView,
    N_ImageViews: u32,
	Layouts: [^]vk.ImageLayout,
    Format: vk.Format,
    Extent: vk.Extent2D,
	Capabilities: vk.SurfaceCapabilitiesKHR,
}

// -----------------------------------------------------------------------------

Vk_Semaphore :: struct {
    ImageAvailable  : [dynamic]vk.Semaphore,
    RenderFinished  : [dynamic]vk.Semaphore,
    InFlight        : [dynamic]vk.Fence,
}

// -----------------------------------------------------------------------------

Vulkan_Base :: struct {

	// --------------------- GENERAL ----------------------------- //
	//
	Instance                  : vk.Instance,
	Window                    : Gpu_Window_State,
	InitDesc                  : Gpu_Desc,
	FrameCount                : u32,
	Device                    : Vk_Device,
	Swapchain                 : Vk_Swapchain,
	Semaphores                : Vk_Semaphore,
	SwapchainGeneration       : u64,

	// --------------------- Immediate Submite ------------------- //
	//
	ImmFence         : vk.Fence,
	ImmCommandBuffer : vk.CommandBuffer,
	ImmCommandPool   : vk.CommandPool,

	// --------------------- Command Buffers --------------------- //
	//
	CommandPool           : [max_frames_in_flight]vk.CommandPool,
	CommandBuffers        : [max_frames_in_flight]vk.CommandBuffer,

	// --------------------- Frame data -------------------------- //
	//
	CurrentFrame : u64,
	LastTimeFrame : f64,
	FramebufferResized : bool,
	LastTime : f64,
	SwapchainImageIdx : u32,

	// --------------------- Debug Utilities --------------------- //
	// 
	DebugMessenger : vk.DebugUtilsMessengerEXT,
	DebugContext:    ^Gpu_Debug_Context,

	// --------------------- VMA Allocator ----------------------- //
	// 
	GPUAllocator : vma.Allocator,

	LogCallback : Gpu_Log_Callback,
	LogUserData : rawptr,
}

Gpu_Debug_Context :: struct {
	callback:  Gpu_Log_Callback,
	user_data: rawptr,
}

// -----------------------------------------------------------------------------

populate_debug_messenger_create_info :: proc(createInfo: ^vk.DebugUtilsMessengerCreateInfoEXT, debug_ctx: ^Gpu_Debug_Context) {
	createInfo.sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
	createInfo.messageSeverity = {.WARNING, .ERROR}
	createInfo.messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE}
	createInfo.pfnUserCallback = debugCallback
	createInfo.pUserData       = debug_ctx
}

gpu_debug_message :: proc(
	severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user_data: rawptr,
) {
	if data == nil || data.pMessage == nil do return
	message, _ := strings.clone_from_cstring(data.pMessage, context.temp_allocator)
	level := Gpu_Log_Level.Debug
	if .ERROR in severity {
		level = .Error
	} else if .WARNING in severity {
		level = .Warning
	} else if .INFO in severity {
		level = .Info
	}
	debug_ctx := (^Gpu_Debug_Context)(user_data)
	if debug_ctx != nil && debug_ctx.callback != nil {
		debug_ctx.callback(level, message, debug_ctx.user_data)
	} else {
		gpu_log_fallback(level, message, nil)
	}
}

// -----------------------------------------------------------------------------

when ODIN_OS == .Windows {
	debugCallback :: proc "stdcall" (
		messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
		messageType: vk.DebugUtilsMessageTypeFlagsEXT,
		pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
		pUserData: rawptr,
	) -> b32 {
		context = runtime.default_context()
		gpu_debug_message(messageSeverity, pCallbackData, pUserData)
		return false
	}
}

when ODIN_OS == .Linux {
	debugCallback :: proc "cdecl" (
		messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
		messageType: vk.DebugUtilsMessageTypeFlagsEXT,
		pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
		pUserData: rawptr,
	) -> b32 {
		context = runtime.default_context()
		gpu_debug_message(messageSeverity, pCallbackData, pUserData)
		return false
	}
}

// -----------------------------------------------------------------------------

command_pool_create_info :: proc(queueFamilyIndex : u32, flags : vk.CommandPoolCreateFlags /*= 0*/) -> vk.CommandPoolCreateInfo {
  info := vk.CommandPoolCreateInfo {};
  info.sType = .COMMAND_POOL_CREATE_INFO;
  info.pNext = nil;
  info.queueFamilyIndex = queueFamilyIndex;
  info.flags = flags;

  return info;
}

// -----------------------------------------------------------------------------


command_buffer_allocate_info :: proc( pool : vk.CommandPool, count : u32 /*= 1*/) -> vk.CommandBufferAllocateInfo {
  info := vk.CommandBufferAllocateInfo {};
  info.sType = .COMMAND_BUFFER_ALLOCATE_INFO;
  info.pNext = nil;

  info.commandPool = pool;
  info.commandBufferCount = count;
  info.level = .PRIMARY;

  return info;
}

// -----------------------------------------------------------------------------

init_commands :: proc(base: ^Vulkan_Base, allocator := context.allocator) -> Gpu_Error {
	_ = allocator
	commandPoolInfo := command_pool_create_info(base.Device.FamilyIndices.Graphics, {.RESET_COMMAND_BUFFER} );

	for i in 0..<int(base.FrameCount) {
		result := vk.CreateCommandPool(base.Device.LogicalDevice, &commandPoolInfo, nil, &base.CommandPool[i])
		if result != .SUCCESS {
			return gpu_error(.Vulkan_Error, "Failed to create frame command pool", result)
		}
		// allocate the default command buffer that we will use for rendering
	    cmdAllocInfo : vk.CommandBufferAllocateInfo = command_buffer_allocate_info(base.CommandPool[i], 1);

	    result = vk.AllocateCommandBuffers(base.Device.LogicalDevice, &cmdAllocInfo, &base.CommandBuffers[i])
		if result != .SUCCESS {
			return gpu_error(.Vulkan_Error, "Failed to allocate frame command buffer", result)
		}
	}

	result := vk.CreateCommandPool(base.Device.LogicalDevice, &commandPoolInfo, nil, &base.ImmCommandPool)
	if result != .SUCCESS {
		return gpu_error(.Vulkan_Error, "Failed to create immediate command pool", result)
	}
	// allocate the default command buffer that we will use for rendering
	cmdAllocInfo : vk.CommandBufferAllocateInfo = command_buffer_allocate_info(base.ImmCommandPool, 1);

	result = vk.AllocateCommandBuffers(base.Device.LogicalDevice, &cmdAllocInfo, &base.ImmCommandBuffer)
	if result != .SUCCESS {
		return gpu_error(.Vulkan_Error, "Failed to allocate immediate command buffer", result)
	}
	return gpu_error_ok()
}

// -----------------------------------------------------------------------------

semaphore_create_info :: proc( flags := vk.SemaphoreCreateFlags{}) -> vk.SemaphoreCreateInfo {
  info := vk.SemaphoreCreateInfo {};
  info.sType = .SEMAPHORE_CREATE_INFO;
  info.pNext = nil;
  info.flags = flags;

  return info;
}

// ------------------------------------------------------------------

fence_create_info :: proc(flags := vk.FenceCreateFlags{}) -> vk.FenceCreateInfo {
  info := vk.FenceCreateInfo {};
  info.sType = .FENCE_CREATE_INFO;
  info.pNext = nil;

  info.flags = flags;

  return info;
}

// ------------------------------------------------------------------

init_sync_structures :: proc(base: ^Vulkan_Base, allocator := context.allocator) -> Gpu_Error {
	_ = allocator
  // create syncronization structures
  // one fence to control when the gpu has finished rendering the frame,
  // and 2 semaphores to syncronize rendering with swapchain
  // we want the fence to start signalled so we can wait on it on the first
  // frame
  fenceCreateInfo     : vk.FenceCreateInfo     = fence_create_info({.SIGNALED});
  semaphoreCreateInfo : vk.SemaphoreCreateInfo = semaphore_create_info();

  frame_count := int(base.FrameCount)
  render_finished_count := int(base.Swapchain.N_Images)

  base.Semaphores.ImageAvailable  = make([dynamic]vk.Semaphore, frame_count);
  base.Semaphores.RenderFinished  = make([dynamic]vk.Semaphore, render_finished_count);
  base.Semaphores.InFlight        = make([dynamic]vk.Fence, frame_count);

  for i in 0..<frame_count {
	result := vk.CreateFence(base.Device.LogicalDevice, &fenceCreateInfo, nil, &base.Semaphores.InFlight[i])
	if result != .SUCCESS {
		return gpu_error(.Vulkan_Error, "Failed to create frame fence", result)
	}

	result = vk.CreateSemaphore(base.Device.LogicalDevice, &semaphoreCreateInfo, nil, &base.Semaphores.ImageAvailable[i])
	if result != .SUCCESS {
		return gpu_error(.Vulkan_Error, "Failed to create image-available semaphore", result)
	}
  }

  for i in 0..< render_finished_count {
	result := vk.CreateSemaphore(base.Device.LogicalDevice, &semaphoreCreateInfo, nil, &base.Semaphores.RenderFinished[i])
	if result != .SUCCESS {
		return gpu_error(.Vulkan_Error, "Failed to create render-finished semaphore", result)
	}
  }

  // Immediate submit fences
  //
	result := vk.CreateFence(base.Device.LogicalDevice, &fenceCreateInfo, nil, &base.ImmFence)
	if result != .SUCCESS {
		return gpu_error(.Vulkan_Error, "Failed to create immediate-submit fence", result)
	}
	return gpu_error_ok()
}

// -----------------------------------------------------------------------------

command_buffer_begin_info :: proc( flags : vk.CommandBufferUsageFlags ) -> vk.CommandBufferBeginInfo
{
	info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		pNext = nil,
		pInheritanceInfo = nil,
		flags = flags,
	}
	return info;
}

// -----------------------------------------------------------------------------

gpu_immediate_submit_begin :: proc( base : ^Vulkan_Base ) -> vk.CommandBuffer
{
	vk_check(vk.ResetFences(base.Device.LogicalDevice, 1, &base.ImmFence));
	vk_check(vk.ResetCommandBuffer(base.ImmCommandBuffer, {}));

	cmd := base.ImmCommandBuffer;

	cmdBeginInfo := command_buffer_begin_info({.ONE_TIME_SUBMIT});

	vk_check(vk.BeginCommandBuffer(cmd, &cmdBeginInfo));

	return cmd;
} 

// -----------------------------------------------------------------------------

gpu_immediate_submit_end :: proc( base : ^Vulkan_Base, cmd : vk.CommandBuffer )
{
	vk_check(vk.EndCommandBuffer(cmd));
	cmdInfo := command_buffer_submit_info(cmd);
	submit := submit_info(&cmdInfo, nil, nil);

	vk_check(vk.QueueSubmit2(base.Device.GraphicsQueue, 1, &submit, base.ImmFence));
	vk_check(vk.WaitForFences(base.Device.LogicalDevice, 1, &base.ImmFence, true, 9999999999));
}

// -----------------------------------------------------------------------------

Layout_Barrier :: struct {
	srcStageMask : vk.PipelineStageFlags2,
	srcAccessMask: vk.AccessFlags2,
	dstStageMask : vk.PipelineStageFlags2,
	dstAccessMask: vk.AccessFlags2,
}

get_layout_transition_barriers :: proc(oldLayout, newLayout: vk.ImageLayout) -> Layout_Barrier {
	b : Layout_Barrier

	switch {
	case oldLayout == .UNDEFINED && newLayout == .TRANSFER_DST_OPTIMAL:
		b = {
			srcStageMask  = {.TOP_OF_PIPE},
			srcAccessMask = {},
			dstStageMask  = {.TRANSFER},
			dstAccessMask = {.TRANSFER_WRITE},
		}
	case oldLayout == .TRANSFER_DST_OPTIMAL && newLayout == .SHADER_READ_ONLY_OPTIMAL:
		b = {
			srcStageMask  = {.TRANSFER},
			srcAccessMask = {.TRANSFER_WRITE},
			dstStageMask  = {.FRAGMENT_SHADER},
			dstAccessMask = {.SHADER_READ},
		}
	case oldLayout == .SHADER_READ_ONLY_OPTIMAL && newLayout == .TRANSFER_DST_OPTIMAL:
		b = {
			srcStageMask  = {.FRAGMENT_SHADER},
			srcAccessMask = {.SHADER_READ},
			dstStageMask  = {.TRANSFER},
			dstAccessMask = {.TRANSFER_WRITE},
		}
	case oldLayout == .UNDEFINED && newLayout == .COLOR_ATTACHMENT_OPTIMAL:
		b = {
			srcStageMask  = {.TOP_OF_PIPE},
			srcAccessMask = {},
			dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
			dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
		}
	case oldLayout == .COLOR_ATTACHMENT_OPTIMAL && newLayout == .PRESENT_SRC_KHR:
		b = {
			srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
			srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
			dstStageMask  = {.BOTTOM_OF_PIPE},
			dstAccessMask = {},
		}
	case oldLayout == .PRESENT_SRC_KHR && newLayout == .COLOR_ATTACHMENT_OPTIMAL:
		b = {
			srcStageMask  = {.TOP_OF_PIPE},
			srcAccessMask = {},
			dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
			dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
		}
	case oldLayout == .UNDEFINED && newLayout == .DEPTH_ATTACHMENT_OPTIMAL:
		b = {
			srcStageMask  = {.TOP_OF_PIPE},
			srcAccessMask = {},
			dstStageMask  = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_READ},
		}
	case oldLayout == .DEPTH_ATTACHMENT_OPTIMAL && newLayout == .DEPTH_ATTACHMENT_OPTIMAL:
		b = {
			srcStageMask  = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
			dstStageMask  = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_READ},
		}
	case oldLayout == .SHADER_READ_ONLY_OPTIMAL && newLayout == .TRANSFER_SRC_OPTIMAL:
		b = {
			srcStageMask  = {.FRAGMENT_SHADER},
			srcAccessMask = {.SHADER_READ},
			dstStageMask  = {.TRANSFER},
			dstAccessMask = {.TRANSFER_READ},
		}
	case oldLayout == .TRANSFER_SRC_OPTIMAL && newLayout == .SHADER_READ_ONLY_OPTIMAL:
		b = {
			srcStageMask  = {.TRANSFER},
			srcAccessMask = {.TRANSFER_READ},
			dstStageMask  = {.FRAGMENT_SHADER},
			dstAccessMask = {.SHADER_READ},
		}
	case oldLayout == .COLOR_ATTACHMENT_OPTIMAL && newLayout == .TRANSFER_SRC_OPTIMAL:
		b = {
			srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
			srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
			dstStageMask  = {.TRANSFER},
			dstAccessMask = {.TRANSFER_READ},
		}
	case oldLayout == .TRANSFER_DST_OPTIMAL && newLayout == .TRANSFER_SRC_OPTIMAL:
		b = {
			srcStageMask  = {.TRANSFER},
			srcAccessMask = {.TRANSFER_WRITE},
			dstStageMask  = {.TRANSFER},
			dstAccessMask = {.TRANSFER_READ},
		}
	case:
		b = {
			srcStageMask  = {.ALL_COMMANDS},
			srcAccessMask = {.MEMORY_WRITE},
			dstStageMask  = {.ALL_COMMANDS},
			dstAccessMask = {.MEMORY_WRITE, .MEMORY_READ},
		}
	}

	return b
}

// -----------------------------------------------------------------------------

transition_image :: proc(
	cmd            : vk.CommandBuffer, 
	image          : vk.Image, 
	currentLayout  : vk.ImageLayout, 
	newLayout      : vk.ImageLayout,
	aspectMask     : vk.ImageAspectFlags = {.COLOR},
) 
{
	barrier := get_layout_transition_barriers(currentLayout, newLayout)

    imageBarrier := vk.ImageMemoryBarrier2{
        sType = .IMAGE_MEMORY_BARRIER_2,
        pNext = nil,
        srcStageMask = barrier.srcStageMask,
        srcAccessMask = barrier.srcAccessMask,
        dstStageMask = barrier.dstStageMask,
        dstAccessMask = barrier.dstAccessMask,
        oldLayout = currentLayout,
        newLayout = newLayout,
    }

    subImage := vk.ImageSubresourceRange{
        aspectMask = aspectMask,
        baseMipLevel = 0,
        levelCount = vk.REMAINING_MIP_LEVELS,
        baseArrayLayer = 0,
        layerCount = vk.REMAINING_ARRAY_LAYERS,
    }

    imageBarrier.subresourceRange = subImage
    imageBarrier.image = image

    depInfo := vk.DependencyInfo{
        sType = .DEPENDENCY_INFO,
        pNext = nil,
        imageMemoryBarrierCount = 1,
        pImageMemoryBarriers = &imageBarrier,
    }

    vk.CmdPipelineBarrier2(cmd, &depInfo)
}


// -----------------------------------------------------------------------------

copy_image_to_image :: proc(
    cmd: vk.CommandBuffer,
    source: vk.Image,
    destination: vk.Image,
    srcSize: vk.Extent2D,
    dstSize: vk.Extent2D,
) {
    blit_region := vk.ImageBlit2{
        sType = .IMAGE_BLIT_2,
        pNext = nil,
        srcSubresource = {
            aspectMask = {vk.ImageAspectFlag.COLOR},
            mipLevel = 0,
            baseArrayLayer = 0,
            layerCount = 1,
        },
        srcOffsets = {
            {0, 0, 0},
            {i32(srcSize.width), i32(srcSize.height), 1},
        },
        dstSubresource = {
            aspectMask = {vk.ImageAspectFlag.COLOR},
            mipLevel = 0,
            baseArrayLayer = 0,
            layerCount = 1,
        },
        dstOffsets = {
            {0, 0, 0},
            {i32(dstSize.width), i32(dstSize.height), 1},
        },
    }

    blit_info := vk.BlitImageInfo2{
        sType = .BLIT_IMAGE_INFO_2,
        pNext = nil,
        srcImage = source,
        srcImageLayout = .TRANSFER_SRC_OPTIMAL,
        dstImage = destination,
        dstImageLayout = .TRANSFER_DST_OPTIMAL,
        regionCount = 1,
        pRegions = &blit_region,
        filter = vk.Filter.LINEAR,
    }

    vk.CmdBlitImage2(cmd, &blit_info)
}

// -----------------------------------------------------------------------------

submit_info :: proc( cmd : ^vk.CommandBufferSubmitInfo, signalSemaphoreInfo : ^vk.SemaphoreSubmitInfo, waitSemaphoreInfo : ^vk.SemaphoreSubmitInfo) -> vk.SubmitInfo2 {
  
  info := vk.SubmitInfo2 {};
  info.sType = .SUBMIT_INFO_2;
  info.pNext = nil;

  info.waitSemaphoreInfoCount = waitSemaphoreInfo == nil ? 0 : 1;
  info.pWaitSemaphoreInfos = waitSemaphoreInfo;

  info.signalSemaphoreInfoCount = signalSemaphoreInfo == nil ? 0 : 1;
  info.pSignalSemaphoreInfos = signalSemaphoreInfo;

  info.commandBufferInfoCount = 1;
  info.pCommandBufferInfos = cmd;

  return info;
}

// -----------------------------------------------------------------------------

semaphore_submit_info :: proc(stageMask : vk.PipelineStageFlags2, semaphore : vk.Semaphore) -> vk.SemaphoreSubmitInfo {
  submitInfo := vk.SemaphoreSubmitInfo{};
  submitInfo.sType = .SEMAPHORE_SUBMIT_INFO;
  submitInfo.pNext = nil;
  submitInfo.semaphore = semaphore;
  submitInfo.stageMask = stageMask;
  submitInfo.deviceIndex = 0;
  submitInfo.value = 1;

  return submitInfo;
}

// -----------------------------------------------------------------------------

command_buffer_submit_info :: proc(cmd : vk.CommandBuffer) -> vk.CommandBufferSubmitInfo 
{
	info := vk.CommandBufferSubmitInfo{};
	info.sType = .COMMAND_BUFFER_SUBMIT_INFO;
	info.pNext = nil;
	info.commandBuffer = cmd;
	info.deviceMask = 0;

	return info;
}

// -----------------------------------------------------------------------------

recreate_swapchain :: proc(base: ^Vulkan_Base) -> bool {
	if vk.DeviceWaitIdle(base.Device.LogicalDevice) != .SUCCESS {
		return false
	}

	err := create_swapchain(base)
	if !gpu_error_is_ok(err) {
		gpu_log(base, .Error, err.message)
		return false
	}

	semaphoreCreateInfo := semaphore_create_info();
	new_render_finished := make([dynamic]vk.Semaphore, int(base.Swapchain.N_Images))
	for i in 0..<base.Swapchain.N_Images {
		result := vk.CreateSemaphore(base.Device.LogicalDevice, &semaphoreCreateInfo, nil, &new_render_finished[i])
		if result != .SUCCESS {
			for j in 0..<i {
				vk.DestroySemaphore(base.Device.LogicalDevice, new_render_finished[j], nil)
			}
			delete(new_render_finished)
			gpu_log(base, .Error, "Failed to recreate swapchain semaphores")
			return false
		}
	}
	for semaphore in base.Semaphores.RenderFinished {
		if semaphore != 0 do vk.DestroySemaphore(base.Device.LogicalDevice, semaphore, nil)
	}
	if base.Semaphores.RenderFinished != nil {
		delete(base.Semaphores.RenderFinished)
	}
	base.Semaphores.RenderFinished = new_render_finished

	base.FramebufferResized = false;
	return true
}

// -----------------------------------------------------------------------------

/* Params:
	- In : Vulkan Base structure 
	- Out : Boolean, true if resize swapchain is necessary, false otherwise.
*/ 
gpu_prepare_frame :: proc(base: ^Vulkan_Base) -> Gpu_Error {
	FrameIdx := base.CurrentFrame;

	// SDL pixel extents account for high-DPI scaling. Polling here catches
	// resizes even when the caller has not forwarded an SDL window event.
	extent := gpu_window_state_extent(&base.Window)
	if extent.width == 0 || extent.height == 0 {
		return gpu_error(.Not_Ready, "Window is minimized")
	}
	if extent != base.Window.last_extent {
		base.FramebufferResized = true
	}
	if base.FramebufferResized {
		if !recreate_swapchain(base) {
			return gpu_error(.Vulkan_Error, "Failed to recreate swapchain")
		}
		return gpu_error(.Not_Ready, "Swapchain was recreated")
	}

	result := vk.WaitForFences(base.Device.LogicalDevice, 1, &base.Semaphores.InFlight[FrameIdx], true, 1000000000)
	if result == .TIMEOUT {
		return gpu_error(.Not_Ready, "Frame fence is not ready", result)
	}
	if result != .SUCCESS {
		return gpu_error(.Vulkan_Error, "Failed to wait for frame fence", result)
	}

	result = vk.AcquireNextImageKHR(
		base.Device.LogicalDevice,
		base.Swapchain.Swapchain,
		1000000000,
		base.Semaphores.ImageAvailable[FrameIdx],
		{},
		&base.SwapchainImageIdx
	);

	if result == .ERROR_OUT_OF_DATE_KHR {
		base.FramebufferResized = true
		return gpu_error(.Swapchain_Out_Of_Date, "Swapchain is out of date", result)
	} else if result == .SUBOPTIMAL_KHR {
		// Keep rendering through transient SUBOPTIMAL; we defer rebuild to the
		// coalesced resize path to avoid repeated stalls while dragging.
		base.FramebufferResized = true
	} else if result == .TIMEOUT {
		// No image became available within the timeout period.
		// This can happen when the window is hidden or the compositor stalls.
		// Skip this frame and try again next time.
		return gpu_error(.Not_Ready, "No swapchain image is ready", result)
	} else if result != .SUCCESS {
		return gpu_error(.Vulkan_Error, "Failed to acquire swapchain image", result)
	}

	// Only reset the fence once we know we have acquired an image and will
	// actually submit work. Otherwise the fence stays unsignaled and the
	// next WaitForFences on this frame slot will timeout.
	result = vk.ResetFences(base.Device.LogicalDevice, 1, &base.Semaphores.InFlight[FrameIdx])
	if result != .SUCCESS {
		return gpu_error(.Vulkan_Error, "Failed to reset frame fence", result)
	}

	return gpu_error_ok()
}

// -----------------------------------------------------------------------------

gpu_begin_render :: proc( base : ^Vulkan_Base ) -> vk.CommandBuffer
{
	FrameIdx := base.CurrentFrame;

	cmdBeginInfo := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		pNext = nil,
		pInheritanceInfo = nil,
		flags = {.ONE_TIME_SUBMIT},
	}

	cmd := base.CommandBuffers[FrameIdx];

	vk_check(vk.ResetCommandBuffer(cmd, {}));
	vk_check(vk.BeginCommandBuffer(cmd, &cmdBeginInfo));

	return cmd;
}

// -----------------------------------------------------------------------------

gpu_end_render :: proc( base : ^Vulkan_Base, cmd : vk.CommandBuffer ) -> bool {

	ResizeSwapchain := false;
	FrameIdx := base.CurrentFrame;
	SwapchainImageIdx := base.SwapchainImageIdx;

	vk_check(vk.EndCommandBuffer(cmd));

	cmdInfo := command_buffer_submit_info( cmd );

	waitInfo := semaphore_submit_info({.COLOR_ATTACHMENT_OUTPUT_KHR}, base.Semaphores.ImageAvailable[FrameIdx]);
	signalInfo := semaphore_submit_info({.ALL_GRAPHICS}, base.Semaphores.RenderFinished[SwapchainImageIdx]);

	submit := submit_info(&cmdInfo, &signalInfo, &waitInfo);

	vk_check(vk.QueueSubmit2(base.Device.GraphicsQueue, 1, &submit, base.Semaphores.InFlight[FrameIdx]));

	// prepare present
	// this will put the image we just rendered to into the visible window.
	// we want to wait on the _renderSemaphore for that,
	// as its necessary that drawing commands have finished before the image is
	// displayed to the user
	//
	presentInfo := vk.PresentInfoKHR {
		sType = .PRESENT_INFO_KHR,
		pNext = nil,
		pSwapchains = &base.Swapchain.Swapchain,
		swapchainCount = 1,
		pWaitSemaphores = &base.Semaphores.RenderFinished[SwapchainImageIdx],
		waitSemaphoreCount = 1,
		pImageIndices = &base.SwapchainImageIdx
	}

	result := vk.QueuePresentKHR(base.Device.PresentationQueue, &presentInfo);

	if result == .ERROR_OUT_OF_DATE_KHR {
		base.FramebufferResized = true
		return true
	} else if result == .SUBOPTIMAL_KHR {
		base.FramebufferResized = true
	} else {
		vk_check(result);
	}

	base.CurrentFrame = (base.CurrentFrame + 1) % u64(base.FrameCount);

	return ResizeSwapchain;
}

// -----------------------------------------------------------------------------

instance_extension_available :: proc(properties: []vk.ExtensionProperties, name: cstring) -> bool {
	for _, i in properties {
		if cstring_equal(cstring(&properties[i].extensionName[0]), name) do return true
	}
	return false
}

gpu_base_init_with_desc :: proc(desc: Gpu_Desc) -> (Vulkan_Base, Gpu_Error) {
	VulkanBase: Vulkan_Base
	window_err := gpu_window_state_init(&VulkanBase.Window, desc.window)
	if !gpu_error_is_ok(window_err) {
		return {}, window_err
	}

	committed := false
	defer if !committed {
		gpu_base_shutdown(&VulkanBase)
	}

	VulkanBase.InitDesc = desc
	VulkanBase.LogCallback = desc.log_callback
	VulkanBase.LogUserData = desc.log_user_data
	frame_count := desc.frames_in_flight
	if frame_count == 0 do frame_count = 2
	if frame_count > max_frames_in_flight {
		return {}, gpu_error(.Invalid_Argument, "frames_in_flight exceeds the supported maximum")
	}
	VulkanBase.FrameCount = frame_count
	if VulkanBase.LogCallback == nil {
		VulkanBase.LogCallback = gpu_log_fallback
	}

	get_instance_proc_addr := SDL.Vulkan_GetVkGetInstanceProcAddr()
	if get_instance_proc_addr == nil {
		return {}, gpu_error(.Sdl_Error, "SDL did not provide vkGetInstanceProcAddr")
	}
	vk.load_proc_addresses_global(auto_cast get_instance_proc_addr)
	if vk.EnumerateInstanceVersion == nil {
		return {}, gpu_error(.Unsupported_Feature, "Vulkan loader does not support Vulkan 1.1 version queries")
	}
	loader_version: u32
	result := vk.EnumerateInstanceVersion(&loader_version)
	if result != .SUCCESS {
		return {}, gpu_error(.Vulkan_Error, "Failed to query Vulkan loader version", result)
	}
	if loader_version < vk.API_VERSION_1_3 {
		return {}, gpu_error(.Unsupported_Feature, "Vulkan 1.3 or newer loader is required")
	}

	instance_extension_count: u32
	result = vk.EnumerateInstanceExtensionProperties(nil, &instance_extension_count, nil)
	if result != .SUCCESS {
		return {}, gpu_error(.Vulkan_Error, "Failed to enumerate Vulkan instance extensions", result)
	}
	instance_extensions := make([]vk.ExtensionProperties, instance_extension_count, context.temp_allocator)
	if instance_extension_count > 0 {
		result = vk.EnumerateInstanceExtensionProperties(nil, &instance_extension_count, raw_data(instance_extensions))
		if result != .SUCCESS {
			return {}, gpu_error(.Vulkan_Error, "Failed to enumerate Vulkan instance extensions", result)
		}
	}

	extension_names := make([dynamic]cstring, 0, len(desc.required_instance_extensions)+len(desc.optional_instance_extensions)+4, context.temp_allocator)
	sdl_extension_count: u32
	sdl_extensions := SDL.Vulkan_GetInstanceExtensions(&sdl_extension_count)
	if sdl_extensions == nil {
		return {}, gpu_error(.Sdl_Error, "SDL failed to report required Vulkan instance extensions")
	}
	for i in 0..<sdl_extension_count {
		append_unique_extension(&extension_names, sdl_extensions[i])
	}
	for extension in desc.required_instance_extensions {
		append_unique_extension(&extension_names, extension)
	}
	if desc.enable_validation {
		append_unique_extension(&extension_names, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
	}
	for extension in extension_names {
		if !instance_extension_available(instance_extensions, extension) {
			return {}, gpu_error(.Unsupported_Feature, "A required Vulkan instance extension is unavailable")
		}
	}
	for extension in desc.optional_instance_extensions {
		if instance_extension_available(instance_extensions, extension) {
			append_unique_extension(&extension_names, extension)
		}
	}

	if desc.enable_validation && !check_validation_layer_support(&VulkanBase) {
		return {}, gpu_error(.Unsupported_Feature, "Requested validation layers are not available")
	}

	app_name := desc.app_name
	if len(app_name) == 0 do app_name = "Polaris System"
	app_name_c := strings.clone_to_cstring(app_name)
	defer delete_cstring(app_name_c)
	appInfo := vk.ApplicationInfo{
		sType              = .APPLICATION_INFO,
		pApplicationName   = app_name_c,
		applicationVersion = vk.MAKE_VERSION(1, 3, 0),
		pEngineName        = "PolarisGPU",
		engineVersion      = vk.MAKE_VERSION(1, 3, 0),
		apiVersion         = vk.API_VERSION_1_3,
	}

	debugCreateInfo: vk.DebugUtilsMessengerCreateInfoEXT
	instance_pnext := desc.instance_pnext
	if desc.enable_validation {
		VulkanBase.DebugContext = new(Gpu_Debug_Context)
		VulkanBase.DebugContext^ = {
			callback = VulkanBase.LogCallback,
			user_data = VulkanBase.LogUserData,
		}
		populate_debug_messenger_create_info(&debugCreateInfo, VulkanBase.DebugContext)
		debugCreateInfo.pNext = desc.instance_pnext
		instance_pnext = &debugCreateInfo
	}
	InstanceInfo := vk.InstanceCreateInfo{
		sType                   = .INSTANCE_CREATE_INFO,
		pNext                   = instance_pnext,
		flags                   = desc.instance_flags,
		pApplicationInfo        = &appInfo,
		enabledExtensionCount   = u32(len(extension_names)),
		ppEnabledExtensionNames = raw_data(extension_names),
	}
	if desc.enable_validation {
		InstanceInfo.enabledLayerCount = u32(len(validation_layers))
		InstanceInfo.ppEnabledLayerNames = &validation_layers[0]
	}

	result = vk.CreateInstance(&InstanceInfo, nil, &VulkanBase.Instance)
	if result != .SUCCESS {
		return {}, gpu_error(.Vulkan_Error, "Failed to create Vulkan instance", result)
	}
	vk.load_proc_addresses_instance(VulkanBase.Instance)

	if desc.enable_validation {
		// The caller's instance chain was consumed by vkCreateInstance; it is
		// not part of VkDebugUtilsMessengerCreateInfoEXT's creation chain.
		debugCreateInfo.pNext = nil
		result = vk.CreateDebugUtilsMessengerEXT(VulkanBase.Instance, &debugCreateInfo, nil, &VulkanBase.DebugMessenger)
		if result != .SUCCESS {
			return {}, gpu_error(.Vulkan_Error, "Failed to create Vulkan debug messenger", result)
		}
	}
	if !gpu_window_state_create_surface(&VulkanBase.Window, VulkanBase.Instance) {
		return {}, gpu_error(.Sdl_Error, "Failed to create SDL Vulkan surface")
	}

	device_count: u32
	result = vk.EnumeratePhysicalDevices(VulkanBase.Instance, &device_count, nil)
	if result != .SUCCESS {
		return {}, gpu_error(.Vulkan_Error, "Failed to enumerate Vulkan physical devices", result)
	}
	if device_count == 0 {
		return {}, gpu_error(.Unsupported_Feature, "No Vulkan physical device found")
	}
	devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
	result = vk.EnumeratePhysicalDevices(VulkanBase.Instance, &device_count, raw_data(devices))
	if result != .SUCCESS {
		return {}, gpu_error(.Vulkan_Error, "Failed to enumerate Vulkan physical devices", result)
	}
	required_device_extensions := build_required_device_extensions(desc, context.temp_allocator)
	best_score: i32 = -1
	for device in devices {
		if !is_suitable_device(&VulkanBase, device, required_device_extensions[:]) do continue
		properties: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(device, &properties)
		score: i32 = 0
		#partial switch properties.deviceType {
		case .DISCRETE_GPU:   score = 300
		case .INTEGRATED_GPU: score = 200
		case .VIRTUAL_GPU:    score = 100
		case .CPU:            score = 0
		case:                 score = 50
		}
		if score > best_score {
			best_score = score
			VulkanBase.Device.PhysicalDevice = device
		}
	}
	if VulkanBase.Device.PhysicalDevice == nil {
		return {}, gpu_error(.Unsupported_Feature, "No device satisfies Vulkan 1.3, queue, swapchain, extension, and feature requirements")
	}

	qfi := find_queue_families(&VulkanBase, VulkanBase.Device.PhysicalDevice)
	VulkanBase.Device.FamilyIndices = qfi
	supported13 := vk.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES}
	supported12 := vk.PhysicalDeviceVulkan12Features{
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext = &supported13,
	}
	supported_features := vk.PhysicalDeviceFeatures2{
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &supported12,
	}
	vk.GetPhysicalDeviceFeatures2(VulkanBase.Device.PhysicalDevice, &supported_features)

	enabled_extensions := make([dynamic]cstring, 0, len(required_device_extensions)+len(desc.optional_device_extensions), context.temp_allocator)
	for extension in required_device_extensions {
		append_unique_extension(&enabled_extensions, extension)
	}
	for extension in desc.optional_device_extensions {
		if !is_promoted_device_extension(extension) && has_device_extension(VulkanBase.Device.PhysicalDevice, extension) {
			append_unique_extension(&enabled_extensions, extension)
		}
	}

	queue_priority: f32 = 1
	queue_create_infos := [2]vk.DeviceQueueCreateInfo{
		0 = {
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = qfi.Graphics,
			queueCount       = 1,
			pQueuePriorities = &queue_priority,
		},
	}
	queue_create_info_count: u32 = 1
	if qfi.Presentation != qfi.Graphics {
		queue_create_infos[1] = vk.DeviceQueueCreateInfo{
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = qfi.Presentation,
			queueCount       = 1,
			pQueuePriorities = &queue_priority,
		}
		queue_create_info_count = 2
	}

	features13 := vk.PhysicalDeviceVulkan13Features{
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext            = desc.device_features_pnext,
		dynamicRendering = true,
		synchronization2 = true,
	}
	features12 := vk.PhysicalDeviceVulkan12Features{
		sType                                          = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext                                          = &features13,
		descriptorIndexing                             = true,
		shaderUniformBufferArrayNonUniformIndexing     = true,
		shaderSampledImageArrayNonUniformIndexing      = true,
		descriptorBindingUniformBufferUpdateAfterBind  = true,
		descriptorBindingSampledImageUpdateAfterBind   = true,
		descriptorBindingUpdateUnusedWhilePending      = true,
		descriptorBindingPartiallyBound                = true,
		runtimeDescriptorArray                         = true,
		bufferDeviceAddress                            = true,
	}
	device_features := vk.PhysicalDeviceFeatures2{
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &features12,
	}
	device_features.features.samplerAnisotropy = supported_features.features.samplerAnisotropy
	device_features.features.fillModeNonSolid = supported_features.features.fillModeNonSolid

	create_info := vk.DeviceCreateInfo{
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &device_features,
		queueCreateInfoCount    = queue_create_info_count,
		pQueueCreateInfos       = &queue_create_infos[0],
		enabledExtensionCount   = u32(len(enabled_extensions)),
		ppEnabledExtensionNames = raw_data(enabled_extensions),
	}
	result = vk.CreateDevice(VulkanBase.Device.PhysicalDevice, &create_info, nil, &VulkanBase.Device.LogicalDevice)
	if result != .SUCCESS {
		return {}, gpu_error(.Vulkan_Error, "Failed to create Vulkan logical device", result)
	}
	vk.load_proc_addresses_device(VulkanBase.Device.LogicalDevice)
	vk.GetDeviceQueue(VulkanBase.Device.LogicalDevice, qfi.Graphics, 0, &VulkanBase.Device.GraphicsQueue)
	vk.GetDeviceQueue(VulkanBase.Device.LogicalDevice, qfi.Presentation, 0, &VulkanBase.Device.PresentationQueue)

	vulkan_functions := vma.create_vulkan_functions()
	AllocatorInfo := vma.AllocatorCreateInfo{
		flags            = {.BUFFER_DEVICE_ADDRESS},
		physicalDevice   = VulkanBase.Device.PhysicalDevice,
		device           = VulkanBase.Device.LogicalDevice,
		instance         = VulkanBase.Instance,
		vulkanApiVersion = vk.API_VERSION_1_3,
		pVulkanFunctions = &vulkan_functions,
	}
	result = vma.CreateAllocator(&AllocatorInfo, &VulkanBase.GPUAllocator)
	if result != .SUCCESS {
		return {}, gpu_error(.Vulkan_Error, "Failed to create VMA allocator", result)
	}

	err := create_swapchain(&VulkanBase, context.allocator)
	if !gpu_error_is_ok(err) do return {}, err
	err = init_commands(&VulkanBase, context.allocator)
	if !gpu_error_is_ok(err) do return {}, err
	err = init_sync_structures(&VulkanBase, context.allocator)
	if !gpu_error_is_ok(err) do return {}, err

	committed = true
	return VulkanBase, gpu_error_ok()
}

gpu_base_shutdown :: proc(base: ^Vulkan_Base) {
	if base == nil {
		return
	}

	device := base.Device.LogicalDevice
	if device != nil {
		_ = vk.DeviceWaitIdle(device)
		for i in 0..<int(base.FrameCount) {
			if base.CommandPool[i] != 0 do vk.DestroyCommandPool(device, base.CommandPool[i], nil)
			if i < len(base.Semaphores.InFlight) && base.Semaphores.InFlight[i] != 0 do vk.DestroyFence(device, base.Semaphores.InFlight[i], nil)
			if i < len(base.Semaphores.ImageAvailable) && base.Semaphores.ImageAvailable[i] != 0 do vk.DestroySemaphore(device, base.Semaphores.ImageAvailable[i], nil)
		}
		for semaphore in base.Semaphores.RenderFinished {
			if semaphore != 0 do vk.DestroySemaphore(device, semaphore, nil)
		}
		if base.ImmCommandPool != 0 do vk.DestroyCommandPool(device, base.ImmCommandPool, nil)
		if base.ImmFence != 0 do vk.DestroyFence(device, base.ImmFence, nil)
	}

	if base.Semaphores.ImageAvailable != nil do delete(base.Semaphores.ImageAvailable)
	if base.Semaphores.RenderFinished != nil do delete(base.Semaphores.RenderFinished)
	if base.Semaphores.InFlight != nil do delete(base.Semaphores.InFlight)
	destroy_swapchain_resources(base, &base.Swapchain, context.allocator)

	if base.GPUAllocator != nil {
		vma.DestroyAllocator(base.GPUAllocator)
	}
	if device != nil {
		vk.DestroyDevice(device, nil)
	}
	if base.Instance != nil {
		if base.Window.surface != 0 {
			vk.DestroySurfaceKHR(base.Instance, base.Window.surface, nil)
		}
		if base.DebugMessenger != 0 {
			vk.DestroyDebugUtilsMessengerEXT(base.Instance, base.DebugMessenger, nil)
		}
		vk.DestroyInstance(base.Instance, nil)
	}
	if base.DebugContext != nil {
		free(base.DebugContext)
		base.DebugContext = nil
	}

	gpu_window_state_shutdown(&base.Window)
	base^ = {}
}
