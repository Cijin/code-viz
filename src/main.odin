package main

import "core:fmt"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"
import "pipeline"
import snap "snapshot"

App :: struct {
	project_dir:     string,
	screenshot_path: string,
	win:             ^Win,
	pipe:            pipeline.Pipeline,
	pipe_running:    bool,
	status:          snap.Build_Status,
	// The newest delta; a failed build never replaces it.
	delta:           ^pipeline.Owned_Delta,
	vet:             ^pipeline.Owned_Vet, // T1 result merged into `delta`
}

app: App

// Registered SDL user event that workers push to wake the UI.
wake_event: u32

notify_ui :: proc() {
	ev: sdl.Event
	ev.type = sdl.EventType(wake_event)
	// A full queue drops the wake-up; the next event drains the channel anyway.
	_ = sdl.PushEvent(&ev)
}

// Applies pipeline events. Returns true when a view should redraw.
drain_pipeline :: proc() -> (redraw: bool) {
	for {
		ev, ok := pipeline.poll(&app.pipe)
		if !ok do break
		redraw = true
		switch ev.kind {
		case .Build_Started:
			app.status = .Building
		case .Build_Failed:
			app.status = .Failed
			fmt.eprintf("substrate: build %d failed\n%s", ev.id, ev.output)
		case .Build_Green:
			pipeline.delta_free(app.delta)
			pipeline.vet_free(app.vet)
			app.vet = nil
			app.delta = ev.delta
			ev.delta = nil
			app.status = .Ok
			// A new build re-pins the largest change.
			if app.win != nil do app.win.pinned = -1
		case .Vet_Ready:
			if app.delta != nil && app.delta.to == ev.id {
				pipeline.vet_free(app.vet)
				app.vet = ev.vet
				ev.vet = nil
				app.delta.safety.vet_total = app.vet.total
				app.delta.safety.vet_new = app.vet.new
				app.delta.safety.vet_ready = true
				}
		}
		pipeline.event_free(&ev)
	}
	return
}

win_for_id :: proc(id: sdl.WindowID) -> ^Win {
	if app.win != nil && app.win.id == id do return app.win
	return nil
}

EMPTY_DELTA: snap.Delta

render_win :: proc(win: ^Win) {
	if win == nil do return
	g = &win.gfx
	clear(&win.hits)
	sdl.SetRenderDrawColor(g.renderer, BG_DESKTOP.r, BG_DESKTOP.g, BG_DESKTOP.b, 255)
	sdl.RenderClear(g.renderer)
	d := app.delta != nil ? &app.delta.delta : &EMPTY_DELTA
	switch win.view {
	case .Memory:
		draw_memory_lens(win, d)
	case .Execution:
		draw_execution_lens(win, d)
	case .Safety:
		draw_safety_lens(win, d)
	case .Blocks:
		draw_blocks_view(win, d, &win.hits)
	}
	sdl.RenderPresent(g.renderer)
}

render_all :: proc() {
	render_win(app.win)
}

show_view :: proc(view: View) {
	if app.win == nil do return
	app.win.view = view
	app.win.pinned = -1
}

handle_action :: proc(a: Action, index := 0) {
	switch a {
	case .None:
	case .Open_Blocks:    show_view(.Blocks)
	case .Open_Execution: show_view(.Execution)
	case .Open_Memory:    show_view(.Memory)
	case .Open_Safety:    show_view(.Safety)
	case .Select_Block:
		// SPEC §8.6: a click pins the row (until the next build).
		if app.win != nil do app.win.pinned = index
	}
}

handle_click :: proc(win: ^Win, x, y: f32) {
	// Topmost first: later hits are drawn over earlier ones.
	#reverse for h in win.hits {
		if rect_contains(h.rect, x, y) {
			handle_action(h.action, h.index)
			return
		}
	}
}

parse_args :: proc() -> bool {
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--screenshot":
			if i + 1 >= len(args) do return false
			app.screenshot_path = args[i + 1]
			i += 1
		case:
			if strings.has_prefix(args[i], "-") do return false
			app.project_dir = args[i]
		}
	}
	return true
}

save_screenshot :: proc(win: ^Win, path: string) -> bool {
	surface := sdl.RenderReadPixels(win.gfx.renderer, nil)
	if surface == nil do return false
	defer sdl.DestroySurface(surface)
	return sdl.SaveBMP(surface, strings.clone_to_cstring(path, context.temp_allocator))
}

main :: proc() {
	if !parse_args() {
		fmt.eprintln("usage: substrate [--screenshot <file.bmp>] <project_dir>")
		os.exit(2)
	}
	if !sdl.Init({.VIDEO, .EVENTS}) {
		fmt.eprintln("substrate: SDL_Init failed:", sdl.GetError())
		os.exit(1)
	}
	defer sdl.Quit()
	if !ttf.Init() {
		fmt.eprintln("substrate: TTF_Init failed:", sdl.GetError())
		os.exit(1)
	}
	defer ttf.Quit()
	font_dir = find_font_dir()

	// One window; the lenses need the room of the mockups' 1440×960 frame,
	// clamped to the display.
	w, h := LENS_W, LENS_H
	bounds: sdl.Rect
	if sdl.GetDisplayUsableBounds(sdl.GetPrimaryDisplay(), &bounds) {
		w = min(w, f32(bounds.w) - 40)
		h = min(h, f32(bounds.h) - 40)
	}
	app.win = win_create("Substrate", w, h)
	if app.win == nil do os.exit(1)
	defer win_destroy(app.win)

	if app.project_dir != "" do app.status = .Building

	wake_event = sdl.RegisterEvents(1)
	if app.project_dir != "" && app.screenshot_path == "" {
		app.pipe_running = pipeline.start(&app.pipe, app.project_dir, notify_ui)
		if !app.pipe_running do fmt.eprintln("substrate: cannot watch", app.project_dir)
	}
	defer if app.pipe_running {
		pipeline.stop(&app.pipe)
		pipeline.delta_free(app.delta)
		pipeline.vet_free(app.vet)
	}

	render_all()
	if app.screenshot_path != "" {
		os.exit(save_screenshot(app.win, app.screenshot_path) ? 0 : 1)
	}

	// Draw only on events: input, resize, or worker results. Idle CPU ~0%.
	for {
		ev: sdl.Event
		if !sdl.WaitEvent(&ev) do continue
		redraw := false
		for got := true; got; got = sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				return
			case sdl.EventType(wake_event):
				if app.pipe_running && drain_pipeline() do redraw = true
			case .WINDOW_CLOSE_REQUESTED:
				return
			case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_DISPLAY_SCALE_CHANGED:
				if win := win_for_id(ev.window.windowID); win != nil do win_update_scale(win)
				redraw = true
			case .WINDOW_EXPOSED:
				redraw = true
			case .MOUSE_MOTION:
				if win := win_for_id(ev.motion.windowID); win != nil {
					win.mouse_x, win.mouse_y = ev.motion.x, ev.motion.y
					redraw = true
				}
			case .WINDOW_MOUSE_LEAVE:
				if win := win_for_id(ev.window.windowID); win != nil {
					win.mouse_x, win.mouse_y = -1, -1
					redraw = true
				}
			case .MOUSE_BUTTON_DOWN:
				if ev.button.button == sdl.BUTTON_LEFT {
					if win := win_for_id(ev.button.windowID); win != nil do handle_click(win, ev.button.x, ev.button.y)
					redraw = true
				}
			}
		}
		if redraw do render_all()
		free_all(context.temp_allocator)
	}
}
