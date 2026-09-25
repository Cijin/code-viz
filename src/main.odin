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
	glance:          snap.Glance,
	hits:            [dynamic]Hit,
	mouse_x:         f32,
	mouse_y:         f32,
	win_w, win_h:    f32,
	pipe:            pipeline.Pipeline,
	pipe_running:    bool,
	// The two newest green snapshots; a failed build never replaces them.
	prev, curr:      ^pipeline.Owned_Snapshot,
}

// Registered SDL user event that workers push to wake the UI.
wake_event: u32

notify_ui :: proc() {
	ev: sdl.Event
	ev.type = sdl.EventType(wake_event)
	// A full queue drops the wake-up; the next event drains the channel anyway.
	_ = sdl.PushEvent(&ev)
}

// Applies pipeline events. Returns true when the view should redraw.
drain_pipeline :: proc() -> (redraw: bool) {
	for {
		ev, ok := pipeline.poll(&app.pipe)
		if !ok do return
		redraw = true
		switch ev.kind {
		case .Build_Started:
			app.glance.status = .Building
		case .Build_Failed:
			app.glance.status = .Failed
			fmt.eprintf("substrate: build %d failed\n%s", ev.id, ev.output)
		case .Build_Green:
			pipeline.snapshot_free(app.prev)
			app.prev = app.curr
			app.curr = ev.snapshot
			ev.snapshot = nil
			app.glance.status = .Ok
			app.glance.to = app.curr.id
			app.glance.from = app.prev != nil ? app.prev.id : app.curr.id
		}
		pipeline.event_free(&ev)
	}
}

app: App

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

update_scale :: proc() {
	s := sdl.GetWindowDisplayScale(g.window)
	if s <= 0 do s = 1
	if s == g.scale && g.hatch != nil do return
	g.scale = s
	reset_text_cache()
	make_hatch_texture()
}

render :: proc() {
	clear(&app.hits)
	sdl.SetRenderDrawColor(g.renderer, BG_DESKTOP.r, BG_DESKTOP.g, BG_DESKTOP.b, 255)
	sdl.RenderClear(g.renderer)
	draw_glance(&app.glance, app.win_w, app.win_h, app.mouse_x, app.mouse_y, &app.hits)
	sdl.RenderPresent(g.renderer)
}

save_screenshot :: proc(path: string) -> bool {
	surface := sdl.RenderReadPixels(g.renderer, nil)
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

	app.win_w, app.win_h = GLANCE_W, GLANCE_H
	g.window = sdl.CreateWindow("Substrate", i32(app.win_w), i32(app.win_h), {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if g.window == nil {
		fmt.eprintln("substrate: window:", sdl.GetError())
		os.exit(1)
	}
	defer sdl.DestroyWindow(g.window)
	g.renderer = sdl.CreateRenderer(g.window, nil)
	if g.renderer == nil {
		fmt.eprintln("substrate: renderer:", sdl.GetError())
		os.exit(1)
	}
	defer sdl.DestroyRenderer(g.renderer)
	sdl.SetRenderDrawBlendMode(g.renderer, {.BLEND})
	g.engine = ttf.CreateRendererTextEngine(g.renderer)
	defer ttf.DestroyRendererTextEngine(g.engine)

	font_dir = find_font_dir()
	update_scale()
	app.glance = snap.sample_glance()

	wake_event = sdl.RegisterEvents(1)
	if app.project_dir != "" && app.screenshot_path == "" {
		app.pipe_running = pipeline.start(&app.pipe, app.project_dir, notify_ui)
		if !app.pipe_running do fmt.eprintln("substrate: cannot watch", app.project_dir)
	}
	defer if app.pipe_running do pipeline.stop(&app.pipe)

	render()
	if app.screenshot_path != "" {
		ok := save_screenshot(app.screenshot_path)
		os.exit(ok ? 0 : 1)
	}

	// Draw only on events: input, resize, or (from M1) worker results.
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
			case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_DISPLAY_SCALE_CHANGED:
				w, h: i32
				sdl.GetWindowSize(g.window, &w, &h)
				app.win_w, app.win_h = f32(w), f32(h)
				update_scale()
				redraw = true
			case .MOUSE_MOTION:
				app.mouse_x, app.mouse_y = ev.motion.x, ev.motion.y
				redraw = true
			case .WINDOW_EXPOSED:
				redraw = true
			}
		}
		if redraw do render()
		free_all(context.temp_allocator)
	}
}
