package main

import "core:fmt"

// Shared chrome for every tab (Memory/Execution/Safety.dc.html): wordmark, tabs and
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
	view:   View,
}

TABS := [5]Tab{
	{"Glance", .Open_Glance, .Glance},
	{"Blocks", .Open_Blocks, .Blocks},
	{"Execution", .Open_Execution, .Execution},
	{"Memory", .Open_Memory, .Memory},
	{"Safety", .Open_Safety, .Safety},
}

// Tab metrics: the lens mockups' size, or a compact row when the window is
// too narrow for it (e.g. the glance panel beside an editor).
@(private = "file")
Tab_Style :: struct {
	font, pad_x, h, gap, pad_side: f32,
	wordmark:                      bool,
}

@(private = "file")
tab_row_width :: proc(st: Tab_Style) -> f32 {
	w := st.pad_side
	if st.wordmark {
		ww := tracked_width(.Mono_SemiBold, 14, 0.08, "SUBSTRATE")
		w += ww + 24
	}
	for tab in TABS {
		tw, _ := text_size(.Sans_Medium, st.font, tab.label)
		w += tw + 2 * st.pad_x + st.gap
	}
	return w
}

// Draws the tab row shared by every view and returns the y where the body
// starts. The right label shows the builds compared, the build status dot
// and, in lenses, the tool that measured the data.
draw_tabs :: proc(win: ^Win, from, to: u32, tool: string, status: Maybe(Color) = nil) -> f32 {
	fill_rect({0, 0, win.w, win.h}, win.view == .Glance ? BG_WINDOW : BG_LENS)
	label := to == 0 ? "" : fmt.tprintf("%d → %d", from, to)
	if tool != "" do label = label == "" ? tool : fmt.tprintf("%s · %s", label, tool)
	lw, _ := text_size(.Mono_Regular, 13, label)

	full := Tab_Style{font = 15, pad_x = 14, h = 40, gap = 4, pad_side = LENS_PAD_X, wordmark = true}
	compact := Tab_Style{font = 13, pad_x = 9, h = 32, gap = 2, pad_side = 12, wordmark = false}
	st := full
	if tab_row_width(full) + lw + 24 + LENS_PAD_X > win.w do st = compact

	top := st.wordmark ? LENS_PAD_TOP : f32(10)
	cy := top + LENS_TOP_H / 2
	x := st.pad_side
	if st.wordmark do x += draw_tracked(.Mono_SemiBold, 14, 0.08, "SUBSTRATE", x, cy, TEXT) + 24

	for tab in TABS {
		tw, _ := text_size(.Sans_Medium, st.font, tab.label)
		r := Rect{x, cy - st.h / 2, tw + 2 * st.pad_x, st.h}
		on := tab.view == win.view
		hovered := rect_contains(r, win.mouse_x, win.mouse_y)
		if on {
			fill_rrect(r, 6, BG_RAISED)
			fill_rect({r.x + 6, r.y + r.h - 2, r.w - 12, 2}, TEXT)
		} else if hovered {
			fill_rrect(r, 6, BG_LANE)
		}
		draw_text(.Sans_Medium, st.font, tab.label, r.x + st.pad_x, cy, on || hovered ? TEXT : TEXT_2)
		append(&win.hits, Hit{rect = r, action = tab.action})
		x += r.w + st.gap
	}

	// Right label; it drops out rather than overlap the tabs.
	right := win.w - st.pad_side
	dot_w := f32(0)
	if _, ok := status.?; ok do dot_w = 8 + 8
	if right - lw - dot_w > x + 12 {
		draw_text_right(.Mono_Regular, 13, label, right, cy, TEXT_3)
		if c, ok := status.?; ok do fill_circle(right - lw - 8 - 4, cy, 8, c)
	} else if c, ok := status.?; ok {
		fill_circle(right - 4, cy, 8, c)
	}
	return top + LENS_TOP_H + (st.wordmark ? LENS_GAP : 8)
}

// Lenses keep their mockup name for the shared row.
draw_lens_top :: proc(win: ^Win, from, to: u32, tool: string) -> f32 {
	return draw_tabs(win, from, to, tool)
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
