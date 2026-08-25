package gpu

import vk "vendor:vulkan"

// One update-after-bind set: sampled images at binding 0, samplers at binding 1,
// and uniform buffers at binding 2.

Gpu_Bindless_Heap :: struct {
	layout: vk.DescriptorSetLayout,
	pool:   vk.DescriptorPool,
	set:    vk.DescriptorSet,

	free_texture_indices: [dynamic]u32,
	free_sampler_indices: [dynamic]u32,
	free_uniform_indices: [dynamic]u32,
	texture_capacity:     u32,
	sampler_capacity:     u32,
	uniform_capacity:     u32,
}

default_texture_heap_capacity :: u32(1024)
default_sampler_heap_capacity :: u32(256)
default_uniform_heap_capacity :: u32(256)

gpu_bindless_init :: proc(ctx: ^Gpu_Context, texture_capacity, sampler_capacity, uniform_capacity: u32) -> Gpu_Error {
	textures := texture_capacity
	samplers := sampler_capacity
	uniforms := uniform_capacity

	if textures == 0 {
		textures = default_texture_heap_capacity
	}
	textures = min(textures, gpu_resource_handle_capacity)

	if samplers == 0 {
		samplers = default_sampler_heap_capacity
	}
	samplers = min(samplers, gpu_resource_handle_capacity)

	if uniforms == 0 {
		uniforms = default_uniform_heap_capacity
	}
	uniforms = min(uniforms, gpu_resource_handle_capacity)

	heap := &ctx.bindless
	heap^ = {}
	heap.texture_capacity = textures
	heap.sampler_capacity = samplers
	heap.uniform_capacity = uniforms

	heap.free_texture_indices = make([dynamic]u32, 0, int(textures), context.allocator)
	heap.free_sampler_indices = make([dynamic]u32, 0, int(samplers), context.allocator)
	heap.free_uniform_indices = make([dynamic]u32, 0, int(uniforms), context.allocator)

	bindings := [?]vk.DescriptorSetLayoutBinding{
		{
			binding         = 0,
			descriptorType  = .SAMPLED_IMAGE,
			descriptorCount = textures,
			stageFlags      = vk.ShaderStageFlags_ALL,
		},
		{
			binding         = 1,
			descriptorType  = .SAMPLER,
			descriptorCount = samplers,
			stageFlags      = vk.ShaderStageFlags_ALL,
		},
		{
			binding         = 2,
			descriptorType  = .UNIFORM_BUFFER,
			descriptorCount = uniforms,
			stageFlags      = vk.ShaderStageFlags_ALL,
		},
	}
	binding_flags := [?]vk.DescriptorBindingFlags{
		{.UPDATE_AFTER_BIND, .UPDATE_UNUSED_WHILE_PENDING, .PARTIALLY_BOUND},
		{.UPDATE_AFTER_BIND, .UPDATE_UNUSED_WHILE_PENDING, .PARTIALLY_BOUND},
		{.UPDATE_AFTER_BIND, .UPDATE_UNUSED_WHILE_PENDING, .PARTIALLY_BOUND},
	}
	binding_flags_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo{
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		pNext         = nil,
		bindingCount  = u32(len(binding_flags)),
		pBindingFlags = raw_data(binding_flags[:]),
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo{
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &binding_flags_info,
		flags        = {.UPDATE_AFTER_BIND_POOL},
		bindingCount = u32(len(bindings)),
		pBindings    = raw_data(bindings[:]),
	}
	result := vk.CreateDescriptorSetLayout(ctx.base.Device.LogicalDevice, &layout_info, nil, &heap.layout)
	if result != .SUCCESS {
		gpu_bindless_shutdown(ctx)
		return gpu_error(.Vulkan_Error, "Failed to create bindless descriptor layout", result)
	}

	pool_sizes := [?]vk.DescriptorPoolSize{
		{type = .SAMPLED_IMAGE, descriptorCount = textures},
		{type = .SAMPLER, descriptorCount = samplers},
		{type = .UNIFORM_BUFFER, descriptorCount = uniforms},
	}
	pool_info := vk.DescriptorPoolCreateInfo{
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		pNext         = nil,
		flags         = {.UPDATE_AFTER_BIND},
		maxSets       = 1,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes[:]),
	}
	result = vk.CreateDescriptorPool(ctx.base.Device.LogicalDevice, &pool_info, nil, &heap.pool)
	if result != .SUCCESS {
		gpu_bindless_shutdown(ctx)
		return gpu_error(.Vulkan_Error, "Failed to create bindless descriptor pool", result)
	}

	alloc_info := vk.DescriptorSetAllocateInfo{
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		pNext              = nil,
		descriptorPool     = heap.pool,
		descriptorSetCount = 1,
		pSetLayouts        = &heap.layout,
	}
	result = vk.AllocateDescriptorSets(ctx.base.Device.LogicalDevice, &alloc_info, &heap.set)
	if result != .SUCCESS {
		gpu_bindless_shutdown(ctx)
		return gpu_error(.Vulkan_Error, "Failed to allocate bindless descriptor set", result)
	}
	return gpu_error_ok()
}

gpu_bindless_shutdown :: proc(ctx: ^Gpu_Context) {
	heap := &ctx.bindless
	if heap.pool != vk.DescriptorPool(0) {
		vk.DestroyDescriptorPool(ctx.base.Device.LogicalDevice, heap.pool, nil)
	}
	if heap.layout != vk.DescriptorSetLayout(0) {
		vk.DestroyDescriptorSetLayout(ctx.base.Device.LogicalDevice, heap.layout, nil)
	}
	if heap.free_texture_indices != nil {
		delete(heap.free_texture_indices)
	}
	if heap.free_sampler_indices != nil {
		delete(heap.free_sampler_indices)
	}
	if heap.free_uniform_indices != nil {
		delete(heap.free_uniform_indices)
	}
	heap^ = {}
}

gpu_bindless_layout :: proc(ctx: ^Gpu_Context) -> vk.DescriptorSetLayout {
	if ctx == nil {
		return vk.DescriptorSetLayout(0)
	}
	return ctx.bindless.layout
}

gpu_bindless_set :: proc(ctx: ^Gpu_Context) -> vk.DescriptorSet {
	if ctx == nil {
		return vk.DescriptorSet(0)
	}
	return ctx.bindless.set
}

gpu_bindless_write_texture :: proc(
	ctx: ^Gpu_Context,
	descriptor_index: u32,
	view: vk.ImageView,
) {
	if ctx == nil || view == vk.ImageView(0) || descriptor_index >= ctx.bindless.texture_capacity {
		return
	}

	image_info := vk.DescriptorImageInfo{
		imageView   = view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	write := vk.WriteDescriptorSet{
		sType           = .WRITE_DESCRIPTOR_SET,
		pNext           = nil,
		dstSet          = ctx.bindless.set,
		dstBinding      = 0,
		dstArrayElement = descriptor_index,
		descriptorCount = 1,
		descriptorType  = .SAMPLED_IMAGE,
		pImageInfo      = &image_info,
	}
	vk.UpdateDescriptorSets(ctx.base.Device.LogicalDevice, 1, &write, 0, nil)
}

gpu_bindless_write_sampler :: proc(ctx: ^Gpu_Context, descriptor_index: u32, sampler: vk.Sampler) {
	if ctx == nil || sampler == vk.Sampler(0) || descriptor_index >= ctx.bindless.sampler_capacity {
		return
	}

	image_info := vk.DescriptorImageInfo{sampler = sampler}
	write := vk.WriteDescriptorSet{
		sType           = .WRITE_DESCRIPTOR_SET,
		pNext           = nil,
		dstSet          = ctx.bindless.set,
		dstBinding      = 1,
		dstArrayElement = descriptor_index,
		descriptorCount = 1,
		descriptorType  = .SAMPLER,
		pImageInfo      = &image_info,
	}
	vk.UpdateDescriptorSets(ctx.base.Device.LogicalDevice, 1, &write, 0, nil)
}

gpu_bindless_write_uniform :: proc(
	ctx: ^Gpu_Context,
	descriptor_index: u32,
	buffer: vk.Buffer,
	offset: vk.DeviceSize = 0,
	range: vk.DeviceSize = vk.DeviceSize(vk.WHOLE_SIZE),
) {
	if ctx == nil ||
	   buffer == vk.Buffer(0) ||
	   range == 0 ||
	   descriptor_index >= ctx.bindless.uniform_capacity {
		return
	}

	buffer_info := vk.DescriptorBufferInfo{
		buffer = buffer,
		offset = offset,
		range  = range,
	}
	write := vk.WriteDescriptorSet{
		sType           = .WRITE_DESCRIPTOR_SET,
		pNext           = nil,
		dstSet          = ctx.bindless.set,
		dstBinding      = 2,
		dstArrayElement = descriptor_index,
		descriptorCount = 1,
		descriptorType  = .UNIFORM_BUFFER,
		pBufferInfo     = &buffer_info,
	}
	vk.UpdateDescriptorSets(ctx.base.Device.LogicalDevice, 1, &write, 0, nil)
}
