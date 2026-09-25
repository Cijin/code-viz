package main

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:thread"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"
import "pipeline"
import snap "snapshot"

App :: struct {
	project_dir:     string,
	screenshot_path: string,
	glance_win:      ^Win,
	lens_win:        ^Win,
	pipe:            pipeline.Pipeline,
	pipe_running:    bool,
	status:          snap.Build_Status,
	// The newest delta; a failed build never replaces it.
	delta:           ^pipeline.Owned_Delta,
	history:         [dynamic]snap.Build_Dots,
	glance:          snap.Glance,
	glance_arena:    virtual.Arena,
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

rebuild_glance :: proc() {
	if app.delta == nil {
		app.glance.status = app.status
		return
	}
	virtual.arena_free_all(&app.glance_arena)
	app.glance = snap.build_glance(&app.delta.delta, &app.history, virtual.arena_allocator(&app.glance_arena))
	app.glance.status = app.status
}

// Applies pipeline events. Returns true when a view should redraw.
drain_pipeline :: proc() -> (redraw: bool) {
	green := false
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
			app.delta = ev.delta
			ev.delta = nil
			app.status = .Ok
			green = true
		}
		pipeline.event_free(&ev)
	}
	// Only a new delta rebuilds the lanes (and adds a build to the history);
	// other events just update the status dot.
	if green do rebuild_glance()
	else do app.glance.status = app.status
	return
}

win_for_id :: proc(id: sdl.WindowID) -> ^Win {
	if app.glance_win != nil && app.glance_win.id == id do return app.glance_win
	if app.lens_win != nil && app.lens_win.id == id do return app.lens_win
	return nil
}

EMPTY_DELTA: snap.Delta

render_win :: proc(win: ^Win) {
	if win == nil do return
	g = &win.gfx
	clear(&win.hits)
	sdl.SetRenderDrawColor(g.renderer, BG_DESKTOP.r, BG_DESKTOP.g, BG_DESKTOP.b, 255)
	sdl.RenderClear(g.renderer)
	switch win.kind {
	case .Glance:
		draw_glance(&app.glance, win.w, win.h, win.mouse_x, win.mouse_y, &win.hits)
	case .Lens:
		d := app.delta != nil ? &app.delta.delta : &EMPTY_DELTA
		switch win.view {
		case .Memory:
			draw_memory_lens(win, d, &win.hits)
		case .Blocks, .Execution, .Safety:
			y := draw_lens_top(win, u32(d.from), u32(d.to), "")
			draw_lens_empty(win, y, "No data")
		}
	}
	sdl.RenderPresent(g.renderer)
}

render_all :: proc() {
	render_win(app.glance_win)
	render_win(app.lens_win)
}

open_lens :: proc(view: Lens_View) {
	if app.lens_win == nil {
		app.lens_win = win_create(.Lens, "Substrate", LENS_W, LENS_H)
		if app.lens_win == nil do return
	}
	app.lens_win.view = view
	sdl.RaiseWindow(app.lens_win.gfx.window)
}

Fix_Job :: struct {
	path:  string,
	line:  int,
	order: []string,
}

// Runs off the UI thread: rewrites the struct's field order in the source
// file. The watcher then rebuilds and the lens shows the result.
apply_fix_worker :: proc(job: ^Fix_Job) {
	defer {
		for s in job.order do delete(s)
		delete(job.order)
		delete(job.path)
		free(job)
	}
	data, err := os.read_entire_file(job.path, context.allocator)
	if err != nil do return
	defer delete(data)
	text, ok := snap.reorder_struct_source(string(data), job.line, job.order)
	if !ok {
		fmt.eprintln("substrate: struct changed since the build; fix not applied")
		return
	}
	defer delete(text)
	_ = os.write_entire_file(job.path, text)
}

apply_fix :: proc() {
	if app.delta == nil || len(app.delta.types) == 0 do return
	td := app.delta.types[0]
	fix, ok := td.suggested.?
	new_t, ok2 := td.new.?
	if !ok || !ok2 do return
	job := new(Fix_Job)
	job.path = fmt.aprintf("%s/%s", app.pipe.project_dir, new_t.pos.file)
	job.line = int(new_t.pos.line)
	job.order = make([]string, len(fix.fields))
	for f, i in fix.fields do job.order[i] = strings.clone(f.name)
	thread.create_and_start_with_poly_data(job, apply_fix_worker, self_cleanup = true)
}

handle_action :: proc(a: Action) {
	switch a {
	case .None:
	case .Open_Glance:
		if app.glance_win != nil do sdl.RaiseWindow(app.glance_win.gfx.window)
	case .Open_Blocks:    open_lens(.Blocks)
	case .Open_Execution: open_lens(.Execution)
	case .Open_Memory:    open_lens(.Memory)
	case .Open_Safety:    open_lens(.Safety)
	case .Apply_Fix:      apply_fix()
	}
}

handle_click :: proc(win: ^Win, x, y: f32) {
	// Topmost first: later hits are drawn over earlier ones.
	#reverse for h in win.hits {
		if rect_contains(h.rect, x, y) {
			handle_action(h.action)
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
	_ = virtual.arena_init_growing(&app.glance_arena)

	app.glance_win = win_create(.Glance, "Substrate", GLANCE_W, GLANCE_H)
	if app.glance_win == nil do os.exit(1)
	defer win_destroy(app.glance_win)
	defer win_destroy(app.lens_win)

	// Without a project, show the M0 sample so the glance matches the mockup.
	if app.project_dir == "" {
		app.glance = snap.sample_glance(virtual.arena_allocator(&app.glance_arena))
	} else {
		app.status = .Building
		rebuild_glance()
	}

	wake_event = sdl.RegisterEvents(1)
	if app.project_dir != "" && app.screenshot_path == "" {
		app.pipe_running = pipeline.start(&app.pipe, app.project_dir, notify_ui)
		if !app.pipe_running do fmt.eprintln("substrate: cannot watch", app.project_dir)
	}
	defer if app.pipe_running {
		pipeline.stop(&app.pipe)
		pipeline.delta_free(app.delta)
	}

	render_all()
	if app.screenshot_path != "" {
		os.exit(save_screenshot(app.glance_win, app.screenshot_path) ? 0 : 1)
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
				if win := win_for_id(ev.window.windowID); win != nil && win == app.lens_win {
					win_destroy(app.lens_win)
					app.lens_win = nil
				} else {
					return
				}
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
