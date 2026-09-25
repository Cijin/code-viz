package main

import "core:fmt"

// Shared lens chrome (Memory/Execution/Safety.dc.html): wordmark, tabs and
// the build/tool label. Lens window padding is 24/32/28 with 18 px gaps.

LENS_PAD_TOP    :: f32(24)
LENS_PAD_X      :: f32(32)
LENS_PAD_BOTTOM :: f32(28)
LENS_GAP        :: f32(18)
LENS_TOP_H      :: f32(44)
LENS_W          :: f32(1440)
LENS_H          :: f32(960)

Tab :: struct {
	label:  string,
	action: Action,
	view:   Lens_View,
}

LENS_TABS := [5]Tab{
	{"Glance", .Open_Glance, .Blocks},
	{"Blocks", .Open_Blocks, .Blocks},
	{"Execution", .Open_Execution, .Execution},
	{"Memory", .Open_Memory, .Memory},
	{"Safety", .Open_Safety, .Safety},
}

// Draws the top row and returns the y where the lens body starts.
draw_lens_top :: proc(win: ^Win, from, to: u32, tool: string) -> f32 {
	fill_rect({0, 0, win.w, win.h}, BG_LENS)
	cy := LENS_PAD_TOP + LENS_TOP_H / 2
	x := LENS_PAD_X
	x += draw_tracked(.Mono_SemiBold, 14, 0.08, "SUBSTRATE", x, cy, TEXT) + 24

	for tab in LENS_TABS {
		tw, _ := text_size(.Sans_Medium, 15, tab.label)
		r := Rect{x, cy - 20, tw + 28, 40}
		on := tab.action != .Open_Glance && tab.view == win.view
		hovered := rect_contains(r, win.mouse_x, win.mouse_y)
		if on {
			fill_rrect(r, 6, BG_RAISED)
			fill_rect({r.x + 6, r.y + r.h - 2, r.w - 12, 2}, TEXT)
		} else if hovered {
			fill_rrect(r, 6, BG_LANE)
		}
		draw_text(.Sans_Medium, 15, tab.label, r.x + 14, cy, on || hovered ? TEXT : TEXT_2)
		append(&win.hits, Hit{r, tab.action})
		x += r.w + 4
	}

	label := fmt.tprintf("%d → %d · %s", from, to, tool)
	draw_text_right(.Mono_Regular, 13, label, win.w - LENS_PAD_X, cy, TEXT_3)
	return LENS_PAD_TOP + LENS_TOP_H + LENS_GAP
}

// `.lay` card: padding 16, radius 8, panel fill and a 1 px line.
draw_card :: proc(r: Rect, outline := LINE, outline_w := f32(1)) {
	fill_rrect(r, 8, BG_PANEL)
	stroke_rrect(r, 8, outline_w, outline)
}

// Mono 12 chip on BG_RAISED (padding 3×8, radius 4). Returns its width.
draw_chip :: proc(s: string, x, cy: f32) -> f32 {
	tw, _ := text_size(.Mono_Regular, 12, s)
	r := Rect{x, cy - 11, tw + 16, 22}
	fill_rrect(r, 4, BG_RAISED)
	draw_text(.Mono_Regular, 12, s, x + 8, cy, TEXT_2)
	return r.w
}

// A lens with nothing to show yet.
draw_lens_empty :: proc(win: ^Win, y: f32, label: string) {
	draw_caps(label, LENS_PAD_X, y + 20)
}
