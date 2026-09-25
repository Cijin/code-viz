package main

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// One SDL window with its own renderer, text engine and caches. The glance
// panel sits beside the editor; lenses open in a second, larger window.

Win_Kind :: enum u8 {
	Glance,
	Lens,
}

Lens_View :: enum u8 {
	Blocks,
	Execution,
	Memory,
	Safety,
}

Win :: struct {
	gfx:     Gfx,
	kind:    Win_Kind,
	view:    Lens_View, // lens windows only
	id:      sdl.WindowID,
	w, h:    f32,
	mouse_x: f32,
	mouse_y: f32,
	hits:    [dynamic]Hit,
}

win_create :: proc(kind: Win_Kind, title: string, w, h: f32) -> ^Win {
	win := new(Win)
	win.kind = kind
	win.w, win.h = w, h
	ctitle := strings.clone_to_cstring(title, context.temp_allocator)
	win.gfx.window = sdl.CreateWindow(ctitle, i32(w), i32(h), {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if win.gfx.window == nil {
		fmt.eprintln("substrate: window:", sdl.GetError())
		free(win)
		return nil
	}
	win.gfx.renderer = sdl.CreateRenderer(win.gfx.window, nil)
	if win.gfx.renderer == nil {
		fmt.eprintln("substrate: renderer:", sdl.GetError())
		sdl.DestroyWindow(win.gfx.window)
		free(win)
		return nil
	}
	sdl.SetRenderDrawBlendMode(win.gfx.renderer, {.BLEND})
	win.gfx.engine = ttf.CreateRendererTextEngine(win.gfx.renderer)
	win.id = sdl.GetWindowID(win.gfx.window)
	win_update_scale(win)
	return win
}

win_destroy :: proc(win: ^Win) {
	if win == nil do return
	prev := g
	g = &win.gfx
	reset_text_cache()
	if g.hatch != nil do sdl.DestroyTexture(g.hatch)
	for _, arc in g.arcs do delete(arc)
	delete(g.arcs)
	delete(g.fonts)
	delete(g.texts)
	delete(g.verts)
	delete(g.indices)
	delete(g.path_a)
	delete(g.path_b)
	ttf.DestroyRendererTextEngine(g.engine)
	sdl.DestroyRenderer(g.renderer)
	sdl.DestroyWindow(g.window)
	delete(win.hits)
	g = prev == &win.gfx ? nil : prev
	free(win)
}

// SPEC §8.1: scale every mockup size by the window's display scale.
win_update_scale :: proc(win: ^Win) {
	prev := g
	defer g = prev
	g = &win.gfx
	iw, ih: i32
	sdl.GetWindowSize(g.window, &iw, &ih)
	win.w, win.h = f32(iw), f32(ih)
	s := sdl.GetWindowDisplayScale(g.window)
	if s <= 0 do s = 1
	if s == g.scale && g.hatch != nil do return
	g.scale = s
	reset_text_cache()
	make_hatch_texture()
}
