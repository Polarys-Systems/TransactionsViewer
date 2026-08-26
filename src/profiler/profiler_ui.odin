package profiler

import "core:fmt"
import "core:math"

import app "../app"
import gpu "../gpu"
import gpu_text "../gpu_text"
import vk "vendor:vulkan"

/*
Profiler overlay renderer and data extraction from thread-local profiler stream.

Example:
	overlay := create_prof_overlay(&ctx)
	defer destroy_prof_overlay(&ctx, &overlay)

	update_prof_overlay_data(&overlay)
	render_prof_overlay(&ctx, &overlay, cmd)
	render_prof_overlay_text(&ctx, &overlay, &ui_renderer, &Text_Renderer)
*/

PROF_OVERLAY_MAX_VERTICES :: 65536
PROF_FRAME_HISTORY_CAP :: 240

Prof_Overlay_Vertex :: struct {
	pos:   [2]f32,
	uv:    [2]f32,
	color: [4]f32,
}

Prof_Overlay_Push_Constants :: struct {
	alpha: f32,
}

Prof_Overlay_Stack_Entry :: struct {
	name:     string,
	start_ns: i64,
}

Prof_Overlay_Bar :: struct {
	name:     string,
	start_ns: i64,
	duration: i64,
	depth:    int,
}

Prof_Overlay_Stat :: struct {
	name:         string,
	inclusive_ns: i64,
	exclusive_ns: i64,
	max_ns:       i64,
	count:        int,
	color:        [4]f32,
}

Prof_Overlay_Frame_Summary :: struct {
	start_ns:    i64,
	duration_ns: i64,
	scope_count: int,
	max_depth:   int,
}

Prof_Overlay_Layout :: struct {
	screen_w:   f32,
	screen_h:   f32,
	left_x:     f32,
	left_y:     f32,
	left_w:     f32,
	left_h:     f32,
	timeline_x: f32,
	timeline_y: f32,
	timeline_w: f32,
	timeline_h: f32,
	plot_x:     f32,
	plot_y:     f32,
	plot_w:     f32,
	plot_h:     f32,
	row_h:      f32,
}

Prof_Overlay :: struct {
	Enabled: bool,
	Pipeline: gpu.Gpu_Pipeline,
	VertexBuffers: [dynamic]gpu.Gpu_Vertex_Buffer,
	VertexBuffer:  ^gpu.Gpu_Vertex_Buffer,
	PushConstants: Prof_Overlay_Push_Constants,
	LastInstanceRead: int,
	CompactStream: bool,
	Stack: [dynamic]Prof_Overlay_Stack_Entry,
	PendingFrameBars: [dynamic]Prof_Overlay_Bar,
	FrameBars: [dynamic]Prof_Overlay_Bar,
	FrameStats: [dynamic]Prof_Overlay_Stat,
	FrameSummary: Prof_Overlay_Frame_Summary,
	FrameHistory: [PROF_FRAME_HISTORY_CAP]f32,
	FrameHistoryCount: int,
	FrameHistoryWrite: int,
}

create_prof_overlay :: proc(ctx: ^gpu.Gpu_Context, allocator := context.allocator) -> Prof_Overlay {
	overlay: Prof_Overlay

	bindings := [1]vk.VertexInputBindingDescription {{
		binding   = 0,
		stride    = auto_cast size_of(Prof_Overlay_Vertex),
		inputRate = .VERTEX,
	}}
	attributes := [3]vk.VertexInputAttributeDescription {
		{
			binding  = 0,
			location = 0,
			format   = .R32G32_SFLOAT,
			offset   = auto_cast offset_of(Prof_Overlay_Vertex, pos),
		},
		{
			binding  = 0,
			location = 1,
			format   = .R32G32_SFLOAT,
			offset   = auto_cast offset_of(Prof_Overlay_Vertex, uv),
		},
		{
			binding  = 0,
			location = 2,
			format   = .R32G32B32A32_SFLOAT,
			offset   = auto_cast offset_of(Prof_Overlay_Vertex, color),
		},
	}
	push_ranges := [1]vk.PushConstantRange {{
		stageFlags = {.FRAGMENT},
		offset     = 0,
		size       = auto_cast size_of(Prof_Overlay_Push_Constants),
	}}

	desc := gpu.gpu_pipeline_desc_default_2d()
	desc.VertShaderPath = "shaders/prof_overlay.vert.spv"
	desc.FragShaderPath = "shaders/prof_overlay.frag.spv"
	desc.VertexBindings = bindings[:]
	desc.VertexAttributes = attributes[:]
	desc.PushConstants = push_ranges[:]
	desc.BlendMode = .ALPHA

	overlay.Pipeline = gpu.gpu_create_graphics_pipeline(ctx, desc)
	frame_count := int(gpu.gpu_frames_in_flight(ctx))
	overlay.VertexBuffers = make([dynamic]gpu.Gpu_Vertex_Buffer, frame_count, frame_count, allocator)
	for slot in 0..<frame_count {
		overlay.VertexBuffers[slot] = gpu.gpu_create_vertex_buffer(ctx, size_of(Prof_Overlay_Vertex), PROF_OVERLAY_MAX_VERTICES)
	}
	overlay.VertexBuffer = &overlay.VertexBuffers[0]
	overlay.PushConstants = {alpha = 0.94}
	overlay.Enabled = false
	overlay.LastInstanceRead = 0
	overlay.CompactStream = true
	overlay.Stack = make([dynamic]Prof_Overlay_Stack_Entry, 0, 256, allocator)
	overlay.PendingFrameBars = make([dynamic]Prof_Overlay_Bar, 0, 1024, allocator)
	overlay.FrameBars = make([dynamic]Prof_Overlay_Bar, 0, 1024, allocator)
	overlay.FrameStats = make([dynamic]Prof_Overlay_Stat, 0, 128, allocator)
	return overlay
}

destroy_prof_overlay :: proc(ctx: ^gpu.Gpu_Context, overlay: ^Prof_Overlay) {
	for &buffer in overlay.VertexBuffers do gpu.gpu_destroy_vertex_buffer(ctx, &buffer)
	delete(overlay.VertexBuffers)
	overlay.VertexBuffer = nil
	gpu.gpu_destroy_pipeline(ctx, &overlay.Pipeline)
	delete(overlay.Stack)
	delete(overlay.PendingFrameBars)
	delete(overlay.FrameBars)
	delete(overlay.FrameStats)
}

update_prof_overlay_data :: proc(overlay: ^Prof_Overlay) {
	if overlay.LastInstanceRead >= len(tl_prof_full_instance) {
		return
	}

	processed_to := len(tl_prof_full_instance)
	for i := overlay.LastInstanceRead; i < processed_to; i += 1 {
		inst := tl_prof_full_instance[i]

		if inst.flame_direction > 0 {
			append(&overlay.Stack, Prof_Overlay_Stack_Entry{
				name     = inst.name,
				start_ns = inst.start_ns,
			})
			continue
		}

		if inst.flame_direction < 0 && len(overlay.Stack) > 0 {
			entry := pop(&overlay.Stack)
			depth := len(overlay.Stack)

			if entry.name == "Render loop" {
				if inst.duration > 0 {
					append(&overlay.PendingFrameBars, Prof_Overlay_Bar{
						name     = entry.name,
						start_ns = entry.start_ns,
						duration = inst.duration,
						depth    = 0,
					})
				}
				prof_overlay_commit_frame(overlay)
				continue
			}

			in_render_scope := false
			for s in overlay.Stack {
				if s.name == "Render loop" {
					in_render_scope = true
					break
				}
			}
			if in_render_scope && inst.duration > 0 {
				append(&overlay.PendingFrameBars, Prof_Overlay_Bar{
					name     = entry.name,
					start_ns = entry.start_ns,
					duration = inst.duration,
					depth    = depth,
				})
			}
		}
	}

	overlay.LastInstanceRead = processed_to
	if overlay.CompactStream && overlay.LastInstanceRead == len(tl_prof_full_instance) {
		clear(&tl_prof_full_instance)
		overlay.LastInstanceRead = 0
	}
}

render_prof_overlay :: proc(ctx: ^gpu.Gpu_Context, overlay: ^Prof_Overlay, cmd: vk.CommandBuffer) {
	overlay.VertexBuffer = &overlay.VertexBuffers[gpu.gpu_current_frame_slot(ctx)]
	if !overlay.Enabled {
		return
	}

	layout := prof_overlay_layout(ctx)
	verts := make([dynamic]Prof_Overlay_Vertex, 0, min(PROF_OVERLAY_MAX_VERTICES, 8192), context.temp_allocator)

	bg := [4]f32{0.012, 0.014, 0.014, 0.86}
	panel := [4]f32{0.035, 0.040, 0.036, 0.92}
	panel_alt := [4]f32{0.050, 0.055, 0.050, 0.92}
	header := [4]f32{0.055, 0.125, 0.245, 0.95}
	grid := [4]f32{0.32, 0.36, 0.34, 0.28}
	grid_strong := [4]f32{0.50, 0.54, 0.50, 0.42}

	prof_overlay_rect_px(&verts, layout, 0, 0, layout.screen_w, layout.screen_h, bg)
	prof_overlay_rect_px(&verts, layout, layout.left_x, layout.left_y, layout.left_w, layout.left_h, panel)
	prof_overlay_rect_px(&verts, layout, layout.left_x, layout.left_y, layout.left_w, 32, header)
	prof_overlay_rect_px(&verts, layout, layout.timeline_x, layout.left_y, layout.timeline_w, layout.plot_y-layout.left_y-8, panel)
	prof_overlay_rect_px(&verts, layout, layout.timeline_x, layout.left_y, layout.timeline_w, 32, header)
	prof_overlay_rect_px(&verts, layout, layout.plot_x, layout.plot_y, layout.plot_w, layout.plot_h, panel)
	prof_overlay_rect_px(&verts, layout, layout.plot_x, layout.plot_y, layout.plot_w, 26, header)

	row_count := layout.timeline_h / layout.row_h
	for i := 0; i < int(row_count); i += 1 {
		row_y := layout.timeline_y + f32(i) * layout.row_h
		if row_y + layout.row_h > layout.timeline_y + layout.timeline_h {
			break
		}
		if i % 2 == 0 {
			prof_overlay_rect_px(&verts, layout, layout.timeline_x, row_y, layout.timeline_w, layout.row_h, panel_alt)
		}
	}

	for i := 0; i <= 10; i += 1 {
		x := layout.timeline_x + layout.timeline_w * f32(i) / 10.0
		color := grid
		if i == 0 || i == 10 {
			color = grid_strong
		}
		prof_overlay_rect_px(&verts, layout, x, layout.timeline_y, 1.0, layout.timeline_h, color)
	}

	if len(overlay.FrameBars) > 0 {
		min_start, max_end := prof_overlay_frame_range(overlay.FrameBars[:])
		total_ns := max_end - min_start
		if total_ns > 0 {
			for b in overlay.FrameBars {
				if b.depth < 0 {
					continue
				}
				row_y := layout.timeline_y + f32(b.depth) * layout.row_h
				if row_y + layout.row_h > layout.timeline_y + layout.timeline_h {
					continue
				}

				x0 := layout.timeline_x + layout.timeline_w * (f32(b.start_ns-min_start) / f32(total_ns))
				x1 := layout.timeline_x + layout.timeline_w * (f32((b.start_ns+b.duration)-min_start) / f32(total_ns))
				if x1 <= x0 {
					x1 = x0 + 2.0
				}
				if x1 - x0 < 2.0 {
					x1 = x0 + 2.0
				}

				col := prof_overlay_name_color(b.name)
				prof_overlay_rect_px(&verts, layout, x0, row_y + 3, x1 - x0, layout.row_h - 6, col)
			}
		}
	}

	prof_overlay_draw_history_geometry(&verts, overlay, layout)

	if len(verts) == 0 {
		return
	}

	if !gpu.gpu_upload_vertices_raw(overlay.VertexBuffer, raw_data(verts[:]), len(verts)) {
		return
	}

	vk.CmdBindPipeline(cmd, .GRAPHICS, overlay.Pipeline.Pipeline)
	vk.CmdPushConstants(
		cmd,
		overlay.Pipeline.Layout,
		{.FRAGMENT},
		0,
		auto_cast size_of(Prof_Overlay_Push_Constants),
		&overlay.PushConstants,
	)

	viewport := vk.Viewport {
		x = 0, y = 0,
		width = f32(gpu.gpu_swapchain_extent(ctx).width), height = f32(gpu.gpu_swapchain_extent(ctx).height),
		minDepth = 0.0, maxDepth = 1.0,
	}
	scissor := vk.Rect2D { offset = {0, 0}, extent = gpu.gpu_swapchain_extent(ctx) }
	vk.CmdSetViewport(cmd, 0, 1, &viewport)
	vk.CmdSetScissor(cmd, 0, 1, &scissor)

	gpu.gpu_bind_vertex_buffer(cmd, overlay.VertexBuffer)
	gpu.gpu_draw_vertices(cmd, overlay.VertexBuffer)
}

prof_overlay_push_text :: proc(
	ui: ^app.UI_Renderer,
	text_renderer: ^gpu_text.Text_Renderer,
	text: string,
	x, y, size: f32,
	color: [4]f32,
	scissor: vk.Rect2D,
) {
	clip_rect := [4]f32{
		f32(scissor.offset.x),
		f32(scissor.offset.y),
		f32(scissor.offset.x) + f32(scissor.extent.width),
		f32(scissor.offset.y) + f32(scissor.extent.height),
	}
	app.ui_renderer_push_text(
		ui,
		text_renderer,
		text,
		x,
		y,
		size,
		text_renderer.DefaultFont,
		color,
		clip_rect,
	)
}

render_prof_overlay_text :: proc(
	ctx: ^gpu.Gpu_Context,
	overlay: ^Prof_Overlay,
	ui: ^app.UI_Renderer,
	text: ^gpu_text.Text_Renderer,
) {
	if !overlay.Enabled {
		return
	}

	layout := prof_overlay_layout(ctx)
	full_scissor := vk.Rect2D { offset = {0, 0}, extent = gpu.gpu_swapchain_extent(ctx) }
	white := [4]f32{0.94, 0.96, 0.92, 1.0}
	muted := [4]f32{0.64, 0.68, 0.64, 1.0}
	hot := [4]f32{1.0, 0.15, 0.42, 1.0}
	warn := [4]f32{0.95, 0.76, 0.22, 1.0}
	ok := [4]f32{0.55, 0.92, 0.18, 1.0}

	prof_overlay_push_text(ui, text, "Profiler (F1)", layout.left_x + 12, layout.left_y + 7, 18, white, full_scissor)

	frame_ms := f64(overlay.FrameSummary.duration_ns) / 1_000_000.0
	budget_color := ok
	if frame_ms > 16.667 {
		budget_color = warn
	}
	if frame_ms > 33.334 {
		budget_color = hot
	}
	summary := fmt.tprintf("%.3f ms  scopes %d  max depth %d", frame_ms, overlay.FrameSummary.scope_count, overlay.FrameSummary.max_depth)
	prof_overlay_push_text(ui, text, summary, layout.left_x + 12, layout.left_y + 42, 15, budget_color, full_scissor)

	header_line := "Zone                    Exc%      Exc     Inc%      Inc   Count"
	prof_overlay_push_text(ui, text, header_line, layout.left_x + 12, layout.left_y + 70, 13, muted, full_scissor)

	max_rows := int((layout.left_h - 96) / 18.0)
	if max_rows > 28 {
		max_rows = 28
	}
	if max_rows > len(overlay.FrameStats) {
		max_rows = len(overlay.FrameStats)
	}
	for i := 0; i < max_rows; i += 1 {
		st := overlay.FrameStats[i]
		inc_pct := 0.0
		exc_pct := 0.0
		if overlay.FrameSummary.duration_ns > 0 {
			inc_pct = 100.0 * f64(st.inclusive_ns) / f64(overlay.FrameSummary.duration_ns)
			exc_pct = 100.0 * f64(st.exclusive_ns) / f64(overlay.FrameSummary.duration_ns)
		}
		name := prof_overlay_short_name(st.name, 22)
		line := fmt.tprintf(
			"%-22s %5.1f %8s %5.1f %8s %5d",
			name,
			exc_pct,
			prof_overlay_format_duration(st.exclusive_ns),
			inc_pct,
			prof_overlay_format_duration(st.inclusive_ns),
			st.count,
		)
		prof_overlay_push_text(ui, text, line, layout.left_x + 12, layout.left_y + 92 + f32(i) * 18, 13, st.color, full_scissor)
	}

	prof_overlay_push_text(ui, text, "Timeline", layout.timeline_x + 12, layout.left_y + 7, 18, white, full_scissor)
	if len(overlay.FrameBars) == 0 {
		prof_overlay_push_text(ui, text, "Waiting for a completed Render loop sample...", layout.timeline_x + 12, layout.timeline_y + 12, 15, muted, full_scissor)
	} else {
		min_start, max_end := prof_overlay_frame_range(overlay.FrameBars[:])
		total_ns := max_end - min_start
		if total_ns > 0 {
			for i := 0; i <= 10; i += 1 {
				x := layout.timeline_x + layout.timeline_w * f32(i) / 10.0
				t_ms := f64(total_ns) * f64(i) / 10.0 / 1_000_000.0
				label := fmt.tprintf("%.2fms", t_ms)
				prof_overlay_push_text(ui, text, label, x + 3, layout.timeline_y - 18, 11, muted, full_scissor)
			}

			label_count := 0
			for b in overlay.FrameBars {
				if label_count >= 80 {
					break
				}
				row_y := layout.timeline_y + f32(b.depth) * layout.row_h
				if row_y + layout.row_h > layout.timeline_y + layout.timeline_h {
					continue
				}
				x0 := layout.timeline_x + layout.timeline_w * (f32(b.start_ns-min_start) / f32(total_ns))
				x1 := layout.timeline_x + layout.timeline_w * (f32((b.start_ns+b.duration)-min_start) / f32(total_ns))
				if x1 - x0 < 68.0 {
					continue
				}
				name := prof_overlay_short_name(b.name, int((x1 - x0) / 8.0))
				label := fmt.tprintf("%s %s", name, prof_overlay_format_duration(b.duration))
				prof_overlay_push_text(ui, text, label, x0 + 4, row_y + 6, 12, white, full_scissor)
				label_count += 1
			}
		}
	}

	history_label := "Frame History"
	if overlay.FrameHistoryCount > 0 {
		avg := prof_overlay_history_average(overlay)
		last := prof_overlay_history_at(overlay, overlay.FrameHistoryCount - 1)
		history_label = fmt.tprintf("Frame History   last %.2f ms   avg %.2f ms", last, avg)
	}
	prof_overlay_push_text(ui, text, history_label, layout.plot_x + 12, layout.plot_y + 6, 15, white, full_scissor)
	prof_overlay_push_text(ui, text, "16.67 ms", layout.plot_x + 10, layout.plot_y + layout.plot_h - 36, 11, muted, full_scissor)
}

prof_overlay_commit_frame :: proc(overlay: ^Prof_Overlay) {
	clear(&overlay.FrameBars)
	append_elems(&overlay.FrameBars, ..overlay.PendingFrameBars[:])
	clear(&overlay.PendingFrameBars)
	prof_overlay_rebuild_frame_stats(overlay)
	if overlay.FrameSummary.duration_ns > 0 {
		prof_overlay_push_frame_history(overlay, f32(f64(overlay.FrameSummary.duration_ns) / 1_000_000.0))
	}
}

prof_overlay_rebuild_frame_stats :: proc(overlay: ^Prof_Overlay) {
	clear(&overlay.FrameStats)
	overlay.FrameSummary = {}
	if len(overlay.FrameBars) == 0 {
		return
	}

	min_start, max_end := prof_overlay_frame_range(overlay.FrameBars[:])
	overlay.FrameSummary.start_ns = min_start
	overlay.FrameSummary.duration_ns = max_end - min_start
	overlay.FrameSummary.scope_count = len(overlay.FrameBars)

	for i := 0; i < len(overlay.FrameBars); i += 1 {
		b := overlay.FrameBars[i]
		if b.depth > overlay.FrameSummary.max_depth {
			overlay.FrameSummary.max_depth = b.depth
		}
		exclusive := prof_overlay_exclusive_ns(overlay.FrameBars[:], i)
		prof_overlay_add_stat(&overlay.FrameStats, b.name, b.duration, exclusive)
	}

	prof_overlay_sort_stats(&overlay.FrameStats)
}

prof_overlay_add_stat :: proc(stats: ^[dynamic]Prof_Overlay_Stat, name: string, inclusive_ns, exclusive_ns: i64) {
	idx := prof_overlay_find_stat(stats, name)
	if idx < 0 {
		append(stats, Prof_Overlay_Stat{
			name         = name,
			inclusive_ns = inclusive_ns,
			exclusive_ns = exclusive_ns,
			max_ns       = inclusive_ns,
			count        = 1,
			color        = prof_overlay_name_color(name),
		})
		return
	}

	st := &stats^[idx]
	st.inclusive_ns += inclusive_ns
	st.exclusive_ns += exclusive_ns
	if inclusive_ns > st.max_ns {
		st.max_ns = inclusive_ns
	}
	st.count += 1
}

prof_overlay_find_stat :: proc(stats: ^[dynamic]Prof_Overlay_Stat, name: string) -> int {
	for i := 0; i < len(stats^); i += 1 {
		if stats^[i].name == name {
			return i
		}
	}
	return -1
}

prof_overlay_sort_stats :: proc(stats: ^[dynamic]Prof_Overlay_Stat) {
	for i := 0; i < len(stats^); i += 1 {
		best := i
		for j := i + 1; j < len(stats^); j += 1 {
			if stats^[j].exclusive_ns > stats^[best].exclusive_ns {
				best = j
			}
		}
		if best != i {
			tmp := stats^[i]
			stats^[i] = stats^[best]
			stats^[best] = tmp
		}
	}
}

prof_overlay_exclusive_ns :: proc(bars: []Prof_Overlay_Bar, idx: int) -> i64 {
	b := bars[idx]
	b_end := b.start_ns + b.duration
	child_total: i64 = 0
	for j := 0; j < len(bars); j += 1 {
		if j == idx {
			continue
		}
		c := bars[j]
		c_end := c.start_ns + c.duration
		if c.depth == b.depth + 1 && c.start_ns >= b.start_ns && c_end <= b_end {
			child_total += c.duration
		}
	}

	exclusive := b.duration - child_total
	if exclusive < 0 {
		return 0
	}
	return exclusive
}

prof_overlay_frame_range :: proc(bars: []Prof_Overlay_Bar) -> (min_start, max_end: i64) {
	if len(bars) == 0 {
		return 0, 0
	}
	min_start = bars[0].start_ns
	max_end = bars[0].start_ns + bars[0].duration
	for b in bars {
		if b.start_ns < min_start {
			min_start = b.start_ns
		}
		end := b.start_ns + b.duration
		if end > max_end {
			max_end = end
		}
	}
	return
}

prof_overlay_push_frame_history :: proc(overlay: ^Prof_Overlay, ms: f32) {
	overlay.FrameHistory[overlay.FrameHistoryWrite] = ms
	overlay.FrameHistoryWrite = (overlay.FrameHistoryWrite + 1) % PROF_FRAME_HISTORY_CAP
	if overlay.FrameHistoryCount < PROF_FRAME_HISTORY_CAP {
		overlay.FrameHistoryCount += 1
	}
}

prof_overlay_history_at :: proc(overlay: ^Prof_Overlay, index: int) -> f32 {
	if overlay.FrameHistoryCount <= 0 || index < 0 || index >= overlay.FrameHistoryCount {
		return 0
	}
	start := overlay.FrameHistoryWrite - overlay.FrameHistoryCount
	if start < 0 {
		start += PROF_FRAME_HISTORY_CAP
	}
	return overlay.FrameHistory[(start + index) % PROF_FRAME_HISTORY_CAP]
}

prof_overlay_history_average :: proc(overlay: ^Prof_Overlay) -> f32 {
	if overlay.FrameHistoryCount <= 0 {
		return 0
	}
	sum: f32 = 0
	for i := 0; i < overlay.FrameHistoryCount; i += 1 {
		sum += prof_overlay_history_at(overlay, i)
	}
	return sum / f32(overlay.FrameHistoryCount)
}

prof_overlay_layout :: proc(ctx: ^gpu.Gpu_Context) -> Prof_Overlay_Layout {
	extent := gpu.gpu_swapchain_extent(ctx)
	w := f32(extent.width)
	h := f32(extent.height)
	pad: f32 = 10

	left_w: f32 = 430
	if w < 1180 {
		left_w = 360
	}
	if w < 820 {
		left_w = w * 0.42
	}
	if left_w < 260 {
		left_w = 260
	}
	if left_w > w - 260 {
		left_w = w - 260
	}
	if left_w < 180 {
		left_w = 180
	}

	plot_h: f32 = 128
	if h < 640 {
		plot_h = 96
	}
	if h < 420 {
		plot_h = 72
	}

	timeline_x := pad + left_w + 10
	timeline_w := w - timeline_x - pad
	if timeline_w < 160 {
		timeline_w = 160
	}

	plot_y := h - plot_h - pad
	timeline_y: f32 = 50
	timeline_h := plot_y - timeline_y - 10
	if timeline_h < 90 {
		timeline_h = 90
	}

	return Prof_Overlay_Layout{
		screen_w   = w,
		screen_h   = h,
		left_x     = pad,
		left_y     = pad,
		left_w     = left_w,
		left_h     = h - pad * 2.0,
		timeline_x = timeline_x,
		timeline_y = timeline_y,
		timeline_w = timeline_w,
		timeline_h = timeline_h,
		plot_x     = timeline_x,
		plot_y     = plot_y,
		plot_w     = timeline_w,
		plot_h     = plot_h,
		row_h      = 24,
	}
}

prof_overlay_rect_px :: proc(verts: ^[dynamic]Prof_Overlay_Vertex, layout: Prof_Overlay_Layout, x, y, w, h: f32, color: [4]f32) {
	if w <= 0 || h <= 0 {
		return
	}
	x0 := (2.0 * x / layout.screen_w) - 1.0
	x1 := (2.0 * (x + w) / layout.screen_w) - 1.0
	y0 := (2.0 * y / layout.screen_h) - 1.0
	y1 := (2.0 * (y + h) / layout.screen_h) - 1.0
	prof_overlay_rect_ndc(verts, x0, y0, x1, y1, color)
}

prof_overlay_rect_ndc :: proc(verts: ^[dynamic]Prof_Overlay_Vertex, x0, y0, x1, y1: f32, color: [4]f32) {
	append(verts, Prof_Overlay_Vertex{pos = {x0, y0}, uv = {0.0, 0.0}, color = color})
	append(verts, Prof_Overlay_Vertex{pos = {x1, y0}, uv = {1.0, 0.0}, color = color})
	append(verts, Prof_Overlay_Vertex{pos = {x1, y1}, uv = {1.0, 1.0}, color = color})
	append(verts, Prof_Overlay_Vertex{pos = {x0, y0}, uv = {0.0, 0.0}, color = color})
	append(verts, Prof_Overlay_Vertex{pos = {x1, y1}, uv = {1.0, 1.0}, color = color})
	append(verts, Prof_Overlay_Vertex{pos = {x0, y1}, uv = {0.0, 1.0}, color = color})
}

prof_overlay_draw_history_geometry :: proc(verts: ^[dynamic]Prof_Overlay_Vertex, overlay: ^Prof_Overlay, layout: Prof_Overlay_Layout) {
	if overlay.FrameHistoryCount <= 0 {
		return
	}

	max_ms: f32 = 16.667
	for i := 0; i < overlay.FrameHistoryCount; i += 1 {
		v := prof_overlay_history_at(overlay, i)
		if v > max_ms {
			max_ms = v
		}
	}
	max_ms *= 1.15
	if max_ms < 20.0 {
		max_ms = 20.0
	}

	plot_top := layout.plot_y + 32
	plot_h := layout.plot_h - 42
	plot_w := layout.plot_w - 20
	plot_x := layout.plot_x + 10
	plot_bottom := plot_top + plot_h

	grid := [4]f32{0.32, 0.36, 0.34, 0.25}
	prof_overlay_rect_px(verts, layout, plot_x, plot_top, plot_w, 1, grid)
	prof_overlay_rect_px(verts, layout, plot_x, plot_bottom, plot_w, 1, grid)

	target_t := 16.667 / max_ms
	target_y := plot_bottom - math.clamp(target_t, 0.0, 1.0) * plot_h
	prof_overlay_rect_px(verts, layout, plot_x, target_y, plot_w, 1.0, [4]f32{0.72, 0.80, 0.30, 0.52})

	bar_w := plot_w / f32(overlay.FrameHistoryCount)
	if bar_w < 1.0 {
		bar_w = 1.0
	}
	for i := 0; i < overlay.FrameHistoryCount; i += 1 {
		v := prof_overlay_history_at(overlay, i)
		t := math.clamp(v / max_ms, 0.0, 1.0)
		x := plot_x + f32(i) * bar_w
		y := plot_bottom - t * plot_h
		h := plot_bottom - y
		col := [4]f32{0.52, 0.90, 0.16, 0.90}
		if v > 16.667 {
			col = [4]f32{0.95, 0.62, 0.12, 0.92}
		}
		if v > 33.334 {
			col = [4]f32{1.0, 0.10, 0.28, 0.94}
		}
		prof_overlay_rect_px(verts, layout, x, y, max(1.0, bar_w - 1.0), h, col)
	}
}

prof_overlay_short_name :: proc(name: string, max_chars: int) -> string {
	if max_chars <= 0 {
		return ""
	}
	if len(name) <= max_chars {
		return name
	}
	return name[:max_chars]
}

prof_overlay_format_duration :: proc(ns: i64) -> string {
	if ns >= 1_000_000 {
		return fmt.tprintf("%.2fms", f64(ns) / 1_000_000.0)
	}
	if ns >= 1_000 {
		return fmt.tprintf("%.2fus", f64(ns) / 1_000.0)
	}
	return fmt.tprintf("%dns", ns)
}

prof_overlay_name_color :: proc(name: string) -> [4]f32 {
	palette := [?][4]f32{
		{0.94, 0.12, 0.39, 1.0},
		{0.13, 0.58, 0.95, 1.0},
		{0.55, 0.86, 0.16, 1.0},
		{0.92, 0.53, 0.14, 1.0},
		{0.58, 0.38, 0.92, 1.0},
		{0.14, 0.72, 0.72, 1.0},
		{0.92, 0.78, 0.18, 1.0},
		{0.78, 0.24, 0.72, 1.0},
	}

	hash: u32 = 2166136261
	for b in transmute([]u8)name {
		hash ~= u32(b)
		hash *= 16777619
	}

	idx := int(hash % u32(len(palette)))
	col := palette[idx]
	lift := (f32((hash >> 8) & 0xff) / 255.0 - 0.5) * 0.16
	col[0] = math.clamp(col[0] + lift, 0.08, 0.98)
	col[1] = math.clamp(col[1] - lift * 0.5, 0.08, 0.98)
	col[2] = math.clamp(col[2] + lift * 0.25, 0.08, 0.98)
	return col
}
