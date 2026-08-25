package gpu

import "core:c"
import "core:strings"

import SDL "vendor:sdl3"
import vk "vendor:vulkan"

Gpu_Window_State :: struct {
	window:         ^SDL.Window,
	surface:        vk.SurfaceKHR,
	owns_video:     bool,
	vulkan_loaded:  bool,
	last_extent:    vk.Extent2D,
}

gpu_window_state_init :: proc(state: ^Gpu_Window_State, desc: Gpu_Window_Desc) -> Gpu_Error {
	state^ = {}

	if .VIDEO not_in SDL.WasInit(SDL.INIT_VIDEO) {
		if !SDL.InitSubSystem(SDL.INIT_VIDEO) {
			return gpu_error(.Sdl_Error, "Failed to initialize SDL video")
		}
		state.owns_video = true
	}

	if !SDL.Vulkan_LoadLibrary(nil) {
		if state.owns_video {
			SDL.QuitSubSystem(SDL.INIT_VIDEO)
		}
		state^ = {}
		return gpu_error(.Sdl_Error, "Failed to load Vulkan through SDL")
	}
	state.vulkan_loaded = true

	flags := SDL.WindowFlags{.VULKAN}
	if desc.resizable do flags += {.RESIZABLE}
	if desc.high_pixel_density do flags += {.HIGH_PIXEL_DENSITY}
	if desc.hidden do flags += {.HIDDEN}
	if desc.borderless do flags += {.BORDERLESS}
	if desc.fullscreen do flags += {.FULLSCREEN}

	title := strings.clone_to_cstring(desc.title)
	defer delete_cstring(title)
	state.window = SDL.CreateWindow(title, max(desc.width, 1), max(desc.height, 1), flags)
	if state.window == nil {
		SDL.Vulkan_UnloadLibrary()
		if state.owns_video {
			SDL.QuitSubSystem(SDL.INIT_VIDEO)
		}
		state^ = {}
		return gpu_error(.Sdl_Error, "Failed to create SDL Vulkan window")
	}

	//SDL_ConvertEventToRenderCoordinates(renderer, &event);
	state.last_extent = gpu_window_state_extent(state)
	return gpu_error_ok()
}

gpu_window_state_extent :: proc(state: ^Gpu_Window_State) -> vk.Extent2D {
	if state == nil || state.window == nil {
		return {}
	}
	w, h: c.int
	if !SDL.GetWindowSizeInPixels(state.window, &w, &h) {
		return {}
	}
	return vk.Extent2D{u32(max(w, 0)), u32(max(h, 0))}
}

gpu_window_state_create_surface :: proc(state: ^Gpu_Window_State, instance: vk.Instance) -> bool {
	if state == nil || state.window == nil {
		return false
	}
	return SDL.Vulkan_CreateSurface(state.window, instance, nil, &state.surface)
}

gpu_window_state_shutdown :: proc(state: ^Gpu_Window_State) {
	if state == nil {
		return
	}
	if state.window != nil {
		SDL.DestroyWindow(state.window)
	}
	if state.vulkan_loaded {
		SDL.Vulkan_UnloadLibrary()
	}
	if state.owns_video {
		SDL.QuitSubSystem(SDL.INIT_VIDEO)
	}
	state^ = {}
}

gpu_window :: proc(ctx: ^Gpu_Context) -> ^SDL.Window {
	if ctx == nil {
		return nil
	}
	return ctx.base.Window.window
}
