package viz

import "core:c"
import "core:fmt"
import "core:os"
import sdl "vendor:sdl3"

build_state :: proc(state: ^App_State) {
	state.status_msg = "Building..."
	fmt.println("Compiling target:", state.target_dir)

	bin_path, ok := compile_target(state.target_dir)
	if !ok {
		state.status_msg = "Build failed - see terminal output"
		return
	}
	state.bin_path = bin_path

	struct_root, structs_ok := extract_structs(bin_path)
	state.struct_root = struct_root
	if !structs_ok {
		state.status_msg = STRUCT_TOOL_HINT
	} else {
		state.status_msg = ""
	}

	clear(&state.own_packages)
	clear(&state.own_decls)
	scan_own_sources(state.target_dir, &state.own_packages, &state.own_decls)
	state.own_structs = filter_own(state.struct_root, state.own_packages)
	group_by_file(state.own_structs, state.own_decls)

	reset_view(state)

	fmt.printf("Loaded: %d structs (%d yours)\n", struct_count(state.struct_root), struct_count(state.own_structs))
}

// Top-level tree for the current view: the user's own structs unless
// internals (core/base/vendor) were toggled on.
view_root :: proc(state: ^App_State) -> ^Node {
	return state.show_internals ? state.struct_root : state.own_structs
}

reset_view :: proc(state: ^App_State) {
	clear(&state.nav_stack)
	state.viewing_struct = nil
	state.active_root = view_root(state)
}

zoom_out :: proc(state: ^App_State) {
	if state.viewing_struct != nil {
		state.viewing_struct = nil
		return
	}
	if len(state.nav_stack) > 0 {
		state.active_root = pop(&state.nav_stack)
	}
}

handle_key :: proc(state: ^App_State, key: sdl.Keycode) {
	switch key {
	case sdl.K_A:
		state.show_internals = !state.show_internals
		reset_view(state)
	case sdl.K_R:
		build_state(state)
	case sdl.K_ESCAPE, sdl.K_BACKSPACE:
		zoom_out(state)
	}
}

handle_click :: proc(state: ^App_State, button: u8) {
	if button == sdl.BUTTON_RIGHT {
		zoom_out(state)
		return
	}
	if button != sdl.BUTTON_LEFT do return
	if state.viewing_struct != nil do return
	if state.hovered == nil do return

	if state.hovered.kind == .Struct {
		state.viewing_struct = state.hovered
		return
	}
	if len(state.hovered.children) > 0 {
		append(&state.nav_stack, state.active_root)
		state.active_root = state.hovered
	}
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: viz <target_dir>")
		os.exit(1)
	}

	state := App_State{target_dir = os.args[1]}
	build_state(&state)

	if !sdl.Init(sdl.INIT_VIDEO) {
		fmt.eprintln("sdl init failed:", sdl.GetError())
		os.exit(1)
	}
	defer sdl.Quit()

	window := sdl.CreateWindow("viz - memory & hardware visualizer", 1440, 900, sdl.WINDOW_RESIZABLE | sdl.WINDOW_HIGH_PIXEL_DENSITY)
	if window == nil {
		fmt.eprintln("create window failed:", sdl.GetError())
		os.exit(1)
	}
	defer sdl.DestroyWindow(window)

	renderer := sdl.CreateRenderer(window, nil)
	if renderer == nil {
		fmt.eprintln("create renderer failed:", sdl.GetError())
		os.exit(1)
	}
	defer sdl.DestroyRenderer(renderer)

	sdl.SetRenderDrawBlendMode(renderer, sdl.BLENDMODE_BLEND)
	apply_pixel_density(renderer, window)

	state.window = window
	state.renderer = renderer
	state.win_w = 1440
	state.win_h = 900

	running := true
	for running {
		free_all(context.temp_allocator)

		mx, my: f32
		_ = sdl.GetMouseState(&mx, &my)

		ev: sdl.Event
		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				running = false
			case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_DISPLAY_SCALE_CHANGED:
				apply_pixel_density(renderer, window)
				w, h: c.int
				sdl.GetWindowSize(window, &w, &h)
				state.win_w = i32(w)
				state.win_h = i32(h)
			case .KEY_DOWN:
				handle_key(&state, ev.key.key)
			case .MOUSE_BUTTON_DOWN:
				handle_click(&state, ev.button.button)
			}
		}

		set_color(renderer, COL_BG)
		sdl.RenderClear(renderer)

		header_h := draw_header(renderer, &state, state.win_w)

		content_area := sdl.FRect{0, header_h, f32(state.win_w), f32(state.win_h) - header_h}

		if state.viewing_struct != nil {
			draw_struct_detail(renderer, state.viewing_struct, content_area, mx, my)
		} else if state.active_root != nil {
			state.hovered = nil
			at_top := len(state.nav_stack) == 0 && state.active_root == view_root(&state)
			if state.show_internals && at_top {
				draw_split_overview(renderer, &state, state.active_root, state.own_structs, content_area, mx, my)
			} else {
				draw_treemap(renderer, state.active_root.children[:], content_area, mx, my, &state.hovered)
			}
			if state.hovered != nil {
				draw_tooltip(renderer, state.hovered, mx, my, state.win_w, state.win_h)
			}
		}

		sdl.RenderPresent(renderer)
	}
}
