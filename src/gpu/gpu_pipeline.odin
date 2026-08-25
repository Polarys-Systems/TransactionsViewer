package gpu

/*
Graphics pipeline and dynamic vertex-buffer helpers.

Example:
	desc := gpu_pipeline_desc_default_2d()
	desc.VertShaderPath = "shaders/ui.vert.spv"
	desc.FragShaderPath = "shaders/ui.frag.spv"
	pipeline := gpu_create_graphics_pipeline(ctx, desc)
	defer gpu_destroy_pipeline(ctx, &pipeline)
*/

import "core:c/libc"
import "core:fmt"
import "core:os"

import vk "vendor:vulkan"

Gpu_Blend_Mode :: enum {
	NONE,
	ALPHA,
	ADDITIVE,
}

Gpu_Pipeline_Desc :: struct {
	VertShaderPath: string,
	FragShaderPath: string,
	VertShaderCode: []u32,
	FragShaderCode: []u32,
	VertEntryPoint: cstring,
	FragEntryPoint: cstring,
	DescriptorLayouts: []vk.DescriptorSetLayout,
	PushConstants: []vk.PushConstantRange,
	VertexAttributes: []vk.VertexInputAttributeDescription,
	VertexBindings: []vk.VertexInputBindingDescription,
	Topology: vk.PrimitiveTopology,
	PolygonMode: vk.PolygonMode,
	CullMode: vk.CullModeFlags,
	FrontFace: vk.FrontFace,
	BlendMode: Gpu_Blend_Mode,
	DepthTest: bool,
	DepthWrite: bool,
	DepthCompareOp: vk.CompareOp,
	ColorFormats: []vk.Format,
	DepthFormat: vk.Format,
}

Gpu_Pipeline :: struct {
	Pipeline: vk.Pipeline,
	Layout:   vk.PipelineLayout,
	BindPoint: vk.PipelineBindPoint,
}

Gpu_Vertex_Buffer :: struct {
	Buffer:           Gpu_Buffer,
	VertexStride:     int,
	CapacityVertices: int,
	VertexCount:      int,
}

gpu_pipeline_desc_default_2d :: proc() -> Gpu_Pipeline_Desc {
	return Gpu_Pipeline_Desc {
		VertEntryPoint   = "main",
		FragEntryPoint   = "main",
		Topology         = .TRIANGLE_LIST,
		PolygonMode      = .FILL,
		CullMode         = {},
		FrontFace        = .COUNTER_CLOCKWISE,
		BlendMode        = .ALPHA,
		DepthTest        = false,
		DepthWrite       = false,
		DepthCompareOp   = .LESS_OR_EQUAL,
		DepthFormat      = .UNDEFINED,
	}
}

load_shader_module :: proc(path: string, device: vk.Device, module: ^vk.ShaderModule) -> bool {
	file, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return false
	}
	if len(file) == 0 || (len(file) % 4) != 0 {
		return false
	}
	code_words := make([]u32, len(file) / 4, context.temp_allocator)
	libc.memcpy(raw_data(code_words), raw_data(file), uint(len(file)))
	module^ = vk.ShaderModule(0)
	create := vk.ShaderModuleCreateInfo{
		sType    = .SHADER_MODULE_CREATE_INFO,
		pNext    = nil,
		codeSize = len(file),
		pCode    = raw_data(code_words),
	}
	vk_check(vk.CreateShaderModule(device, &create, nil, module))
	return module^ != vk.ShaderModule(0)
}

load_shader_module_from_code :: proc(code: []u32, device: vk.Device, module: ^vk.ShaderModule) -> bool {
	if len(code) == 0 {
		return false
	}
	module^ = vk.ShaderModule(0)
	create := vk.ShaderModuleCreateInfo{
		sType    = .SHADER_MODULE_CREATE_INFO,
		pNext    = nil,
		codeSize = len(code) * size_of(u32),
		pCode    = raw_data(code),
	}
	vk_check(vk.CreateShaderModule(device, &create, nil, module))
	return module^ != vk.ShaderModule(0)
}

gpu_create_graphics_pipeline :: proc(ctx: ^Gpu_Context, desc: Gpu_Pipeline_Desc) -> Gpu_Pipeline {
	for push_range in desc.PushConstants {
		if push_range.offset + push_range.size > ctx.capabilities.max_push_constants_size {
			panic("[GPU] Graphics pipeline push constants exceed the device limit")
		}
	}

	vert_shader := vk.ShaderModule(0)
	if len(desc.VertShaderCode) > 0 {
		if !load_shader_module_from_code(desc.VertShaderCode, ctx.base.Device.LogicalDevice, &vert_shader) {
			panic("[ERROR] Failed to load vertex shader code")
		}
	} else if len(desc.VertShaderPath) > 0 {
		if !load_shader_module(desc.VertShaderPath, ctx.base.Device.LogicalDevice, &vert_shader) {
			panic("[ERROR] Failed to load vertex shader")
		}
	} else {
		panic("[ERROR] Missing vertex shader source")
	}

	frag_shader := vk.ShaderModule(0)
	if len(desc.FragShaderCode) > 0 {
		if !load_shader_module_from_code(desc.FragShaderCode, ctx.base.Device.LogicalDevice, &frag_shader) {
			panic("[ERROR] Failed to load fragment shader code")
		}
	} else if len(desc.FragShaderPath) > 0 {
		if !load_shader_module(desc.FragShaderPath, ctx.base.Device.LogicalDevice, &frag_shader) {
			panic("[ERROR] Failed to load fragment shader")
		}
	} else {
		panic("[ERROR] Missing fragment shader source")
	}

	vert_entry := desc.VertEntryPoint
	if vert_entry == nil {
		vert_entry = "main"
	}
	frag_entry := desc.FragEntryPoint
	if frag_entry == nil {
		frag_entry = "main"
	}

	stages := [2]vk.PipelineShaderStageCreateInfo{
		{
				sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage  = {.VERTEX},
				module = vert_shader,
				pName  = vert_entry,
			},
			{
				sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage  = {.FRAGMENT},
				module = frag_shader,
				pName  = frag_entry,
			},
		}

	vertex_input := vk.PipelineVertexInputStateCreateInfo{
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}
	if len(desc.VertexAttributes) > 0 {
		vertex_input.vertexAttributeDescriptionCount = auto_cast len(desc.VertexAttributes)
		vertex_input.pVertexAttributeDescriptions = raw_data(desc.VertexAttributes)
		vertex_input.vertexBindingDescriptionCount = auto_cast len(desc.VertexBindings)
		vertex_input.pVertexBindingDescriptions = raw_data(desc.VertexBindings)
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo{
		sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology               = desc.Topology,
		primitiveRestartEnable = false,
	}

	rasterizer := vk.PipelineRasterizationStateCreateInfo{
		sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode             = desc.PolygonMode,
		lineWidth               = 1.0,
		cullMode                = desc.CullMode,
		frontFace               = desc.FrontFace,
		depthClampEnable        = false,
		rasterizerDiscardEnable = false,
	}

	multisample := vk.PipelineMultisampleStateCreateInfo{
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
		sampleShadingEnable  = false,
	}

	blend_attachment := vk.PipelineColorBlendAttachmentState{
		colorWriteMask = {.R, .G, .B, .A},
	}
	switch desc.BlendMode {
	case .NONE:
		blend_attachment.blendEnable = false
	case .ALPHA:
		blend_attachment.blendEnable = true
		blend_attachment.srcColorBlendFactor = .SRC_ALPHA
		blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
		blend_attachment.colorBlendOp = .ADD
		blend_attachment.srcAlphaBlendFactor = .ONE
		blend_attachment.dstAlphaBlendFactor = .ZERO
		blend_attachment.alphaBlendOp = .ADD
	case .ADDITIVE:
		blend_attachment.blendEnable = true
		blend_attachment.srcColorBlendFactor = .SRC_ALPHA
		blend_attachment.dstColorBlendFactor = .ONE
		blend_attachment.colorBlendOp = .ADD
		blend_attachment.srcAlphaBlendFactor = .ONE
		blend_attachment.dstAlphaBlendFactor = .ZERO
		blend_attachment.alphaBlendOp = .ADD
	}

	color_formats := desc.ColorFormats
	color_format_fallback := [1]vk.Format{gpu_swapchain_format(ctx)}
	if len(color_formats) == 0 {
		color_formats = color_format_fallback[:]
	}
	blend_attachments := make([]vk.PipelineColorBlendAttachmentState, len(color_formats), context.temp_allocator)
	for i in 0..<len(blend_attachments) {
		blend_attachments[i] = blend_attachment
	}
	blend := vk.PipelineColorBlendStateCreateInfo{
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable   = false,
		attachmentCount = u32(len(blend_attachments)),
		pAttachments    = raw_data(blend_attachments),
	}

	depth := vk.PipelineDepthStencilStateCreateInfo{
		sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
	}
	if desc.DepthTest {
		depth.depthTestEnable = true
		depth.depthWriteEnable = auto_cast desc.DepthWrite
		depth.depthCompareOp = desc.DepthCompareOp
	}

	viewport_state := vk.PipelineViewportStateCreateInfo{
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}

	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dyn_state := vk.PipelineDynamicStateCreateInfo{
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = 2,
		pDynamicStates    = &dynamic_states[0],
	}

	layout_info := vk.PipelineLayoutCreateInfo{
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
		pNext = nil,
	}
	set_layouts := make([]vk.DescriptorSetLayout, len(desc.DescriptorLayouts)+1, context.temp_allocator)
	set_layouts[0] = gpu_bindless_layout(ctx)
	copy(set_layouts[1:], desc.DescriptorLayouts)
	if len(set_layouts) > 0 {
		layout_info.setLayoutCount = u32(len(set_layouts))
		layout_info.pSetLayouts = raw_data(set_layouts)
	}
	if len(desc.PushConstants) > 0 {
		layout_info.pushConstantRangeCount = auto_cast len(desc.PushConstants)
		layout_info.pPushConstantRanges = raw_data(desc.PushConstants)
	}

	pipeline_layout: vk.PipelineLayout
	vk_check(vk.CreatePipelineLayout(ctx.base.Device.LogicalDevice, &layout_info, nil, &pipeline_layout))

	rendering := vk.PipelineRenderingCreateInfo{
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = u32(len(color_formats)),
		pColorAttachmentFormats = raw_data(color_formats),
		depthAttachmentFormat   = desc.DepthFormat,
	}

	create := vk.GraphicsPipelineCreateInfo{
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering,
		stageCount          = 2,
		pStages             = &stages[0],
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisample,
		pColorBlendState    = &blend,
		pDepthStencilState  = &depth,
		pDynamicState       = &dyn_state,
		layout              = pipeline_layout,
	}

	gfx: vk.Pipeline
	if vk.CreateGraphicsPipelines(ctx.base.Device.LogicalDevice, vk.PipelineCache(0), 1, &create, nil, &gfx) != .SUCCESS {
		if vert_shader != vk.ShaderModule(0) {
			vk.DestroyShaderModule(ctx.base.Device.LogicalDevice, vert_shader, nil)
		}
		if frag_shader != vk.ShaderModule(0) {
			vk.DestroyShaderModule(ctx.base.Device.LogicalDevice, frag_shader, nil)
		}
		vk.DestroyPipelineLayout(ctx.base.Device.LogicalDevice, pipeline_layout, nil)
		panic("[ERROR] Failed to create graphics pipeline")
	}

	if vert_shader != vk.ShaderModule(0) {
		vk.DestroyShaderModule(ctx.base.Device.LogicalDevice, vert_shader, nil)
	}
	if frag_shader != vk.ShaderModule(0) {
		vk.DestroyShaderModule(ctx.base.Device.LogicalDevice, frag_shader, nil)
	}

	return Gpu_Pipeline{Pipeline = gfx, Layout = pipeline_layout, BindPoint = .GRAPHICS}
}

gpu_destroy_pipeline :: proc(ctx: ^Gpu_Context, pipeline: ^Gpu_Pipeline) {
	if pipeline == nil do return
	gpu_defer_pipeline_destroy(ctx, pipeline.Pipeline, pipeline.Layout)
	pipeline^ = {}
}

Gpu_Compute_Pipeline_Desc :: struct {
	shader_path: string,
	shader_code: []u32,
	entry_point: cstring,
	descriptor_layouts: []vk.DescriptorSetLayout,
	push_constants: []vk.PushConstantRange,
}

gpu_create_compute_pipeline :: proc(ctx: ^Gpu_Context, desc: Gpu_Compute_Pipeline_Desc) -> Gpu_Pipeline {
	for push_range in desc.push_constants {
		if push_range.offset + push_range.size > ctx.capabilities.max_push_constants_size {
			panic("[GPU] Compute pipeline push constants exceed the device limit")
		}
	}
	shader: vk.ShaderModule
	ok := false
	if len(desc.shader_code) > 0 {
		ok = load_shader_module_from_code(desc.shader_code, ctx.base.Device.LogicalDevice, &shader)
	} else {
		ok = load_shader_module(desc.shader_path, ctx.base.Device.LogicalDevice, &shader)
	}
	if !ok {
		panic("[GPU] Failed to load compute shader")
	}
	defer vk.DestroyShaderModule(ctx.base.Device.LogicalDevice, shader, nil)

	entry := desc.entry_point
	if entry == nil do entry = "main"
	set_layouts := make([]vk.DescriptorSetLayout, len(desc.descriptor_layouts)+1, context.temp_allocator)
	set_layouts[0] = gpu_bindless_layout(ctx)
	copy(set_layouts[1:], desc.descriptor_layouts)
	layout_info := vk.PipelineLayoutCreateInfo{
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = u32(len(set_layouts)),
		pSetLayouts = raw_data(set_layouts),
		pushConstantRangeCount = u32(len(desc.push_constants)),
		pPushConstantRanges = raw_data(desc.push_constants),
	}
	layout: vk.PipelineLayout
	vk_check(vk.CreatePipelineLayout(ctx.base.Device.LogicalDevice, &layout_info, nil, &layout))
	stage := vk.PipelineShaderStageCreateInfo{
		sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage = {.COMPUTE},
		module = shader,
		pName = entry,
	}
	info := vk.ComputePipelineCreateInfo{
		sType = .COMPUTE_PIPELINE_CREATE_INFO,
		stage = stage,
		layout = layout,
	}
	pipeline: vk.Pipeline
	result := vk.CreateComputePipelines(ctx.base.Device.LogicalDevice, vk.PipelineCache(0), 1, &info, nil, &pipeline)
	if result != .SUCCESS {
		vk.DestroyPipelineLayout(ctx.base.Device.LogicalDevice, layout, nil)
		panic("[GPU] Failed to create compute pipeline")
	}
	return Gpu_Pipeline{Pipeline = pipeline, Layout = layout, BindPoint = .COMPUTE}
}

gpu_bind_pipeline :: proc(ctx: ^Gpu_Context, cmd: vk.CommandBuffer, pipeline: ^Gpu_Pipeline) {
	if ctx == nil || pipeline == nil || pipeline.Pipeline == vk.Pipeline(0) {
		return
	}
	vk.CmdBindPipeline(cmd, pipeline.BindPoint, pipeline.Pipeline)
	set := gpu_bindless_set(ctx)
	vk.CmdBindDescriptorSets(cmd, pipeline.BindPoint, pipeline.Layout, 0, 1, &set, 0, nil)
}

gpu_push_constants :: proc(
	ctx: ^Gpu_Context,
	cmd: vk.CommandBuffer,
	pipeline: ^Gpu_Pipeline,
	stages: vk.ShaderStageFlags,
	data: rawptr,
	size: u32,
	offset: u32 = 0,
) -> bool {
	if ctx == nil || pipeline == nil || data == nil || size == 0 {
		return false
	}
	if offset + size > ctx.capabilities.max_push_constants_size {
		return false
	}
	vk.CmdPushConstants(cmd, pipeline.Layout, stages, offset, size, data)
	return true
}

gpu_create_vertex_buffer :: proc(ctx: ^Gpu_Context, vertex_stride: int, max_vertices: int, usage := vk.BufferUsageFlags{.VERTEX_BUFFER}, memory_kind := Gpu_Memory_Kind.Upload) -> Gpu_Vertex_Buffer {
	capacity := u64(vertex_stride * max_vertices)
	buffer := gpu_create_buffer(ctx, capacity, usage, memory_kind, "vertex_buffer")
	return Gpu_Vertex_Buffer{
		Buffer           = buffer,
		VertexStride     = vertex_stride,
		CapacityVertices = max_vertices,
		VertexCount      = 0,
	}
}

gpu_destroy_vertex_buffer :: proc(ctx: ^Gpu_Context, vb: ^Gpu_Vertex_Buffer) {
	if vb.Buffer.buffer != vk.Buffer(0) {
		gpu_destroy_buffer(ctx, &vb.Buffer)
		vb.Buffer = {}
	}
	vb.VertexCount = 0
}

gpu_upload_vertices_raw :: proc(vb: ^Gpu_Vertex_Buffer, data: rawptr, vertex_count: int) -> bool {
	if vertex_count > vb.CapacityVertices {
		fmt.eprintf("[ERROR] Vertex upload overflow: %d > %d\n", vertex_count, vb.CapacityVertices)
		return false
	}

	byte_size := uint(vertex_count * vb.VertexStride)
	libc.memcpy(vb.Buffer.cpu, data, byte_size)
	gpu_flush_buffer(&vb.Buffer, 0, u64(byte_size))
	vb.VertexCount = vertex_count
	return true
}

gpu_bind_vertex_buffer :: proc(cmd: vk.CommandBuffer, vb: ^Gpu_Vertex_Buffer, binding: u32 = 0) {
	offset: vk.DeviceSize = 0
	vk.CmdBindVertexBuffers(cmd, binding, 1, &vb.Buffer.buffer, &offset)
}

gpu_draw_vertices :: proc(cmd: vk.CommandBuffer, vb: ^Gpu_Vertex_Buffer, first_vertex: u32 = 0, instance_count: u32 = 1, first_instance: u32 = 0) {
	if vb.VertexCount <= 0 {
		return
	}
	vk.CmdDraw(cmd, auto_cast vb.VertexCount, instance_count, first_vertex, first_instance)
}
