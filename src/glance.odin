package main

import "core:fmt"
import snap "snapshot"

Action :: enum u8 {
	None,
	Open_Glance,
	Apply_Fix,
	Toggle_Asm,
	Select_Block,
	Open_Blocks,
	Open_Execution,
	Open_Memory,
	Open_Safety,
}

Hit :: struct {
	rect:   Rect,
	action: Action,
	index:  int, // Select_Block: the row
}

LINE_H_12 :: f32(16) // line box of 12 px text
LINE_H_11 :: f32(15)

format_delta :: proc(v: int, unit := "") -> string {
	sep := unit == "" ? "" : " "
	switch {
	case v > 0: return fmt.tprintf("+%d%s%s", v, sep, unit)
	case v < 0: return fmt.tprintf("−%d%s%s", -v, sep, unit)
	}
	return "="
}

delta_color :: proc(v: int) -> Color {
	return v > 0 ? COST : (v < 0 ? GAIN : TEXT_3)
}

status_color :: proc(s: snap.Build_Status) -> Color {
	switch s {
	case .Ok:       return TEXT_2
	case .Building: return TEXT_4
	case .Failed:   return COST
	}
	return TEXT_2
}

// Lane card frame plus its first row (caps label, main symbol). Returns the
// y where the lane's content starts.
@(private = "file")
lane_frame :: proc(r: Rect, label, symbol: string, hovered: bool) -> f32 {
	fill_rrect(r, LANE_RADIUS, BG_LANE)
	stroke_rrect(r, LANE_RADIUS, 1, hovered ? LINE_STRONG : LINE)
	cy := r.y + LANE_PAD_Y + LINE_H_12 / 2
	draw_caps(label, r.x + LANE_PAD_X, cy)
	draw_text_right(.Mono_Regular, 12, symbol, r.x + r.w - LANE_PAD_X, cy, TEXT_3)
	return r.y + LANE_PAD_Y + LINE_H_12 + LANE_ROW_GAP
}

COLLAPSED_LANE_H :: LANE_PAD_Y * 2 + LINE_H_12

@(private = "file")
draw_collapsed_lane :: proc(r: Rect, label: string, hovered: bool) {
	fill_rrect(r, LANE_RADIUS, BG_LANE)
	stroke_rrect(r, LANE_RADIUS, 1, hovered ? LINE_STRONG : LINE)
	cy := r.y + r.h / 2
	draw_caps(label, r.x + LANE_PAD_X, cy)
	draw_text_right(.Mono_Regular, 12, "=", r.x + r.w - LANE_PAD_X, cy, TEXT_3)
}

// The big delta number in its fixed 80 px column.
@(private = "file")
draw_lane_delta :: proc(text: string, v: int, x, cy: f32) {
	draw_text(.Mono_SemiBold, LANE_DELTA, text, x, cy, delta_color(v))
}

INLINE_ROW_H :: f32(26)
DELTA_ROW_MIN :: LANE_DELTA

@(private = "file")
exec_lane_height :: proc(l: ^snap.Exec_Lane, inner_w: f32) -> f32 {
	if !l.changed do return COLLAPSED_LANE_H
	strip_h := glyph_strip_height(l.glyphs, inner_w - LANE_DELTA_COL - LANE_DELTA_GAP, 3, .Glance)
	h := LANE_PAD_Y + LINE_H_12 + LANE_ROW_GAP + max(DELTA_ROW_MIN, strip_h) + LANE_PAD_Y
	if _, ok := l.inline.?; ok do h += LANE_ROW_GAP + INLINE_ROW_H
	return h
}

// A mono 11 px box (`.bx`): 3×7 padding, radius 4, 1 px outline.
@(private = "file")
draw_box_label :: proc(s: string, x, cy: f32, hot: bool) -> f32 {
	tw, _ := text_size(.Mono_Regular, 11, s)
	r := Rect{x, cy - (LINE_H_11 + 6) / 2, tw + 14, LINE_H_11 + 6}
	stroke_rrect(r, 4, hot ? 1.5 : 1, hot ? COST : LINE_STRONG)
	draw_text(.Mono_Regular, 11, s, x + 7, cy, hot ? TEXT : TEXT_2)
	return r.w
}

@(private = "file")
draw_exec_lane :: proc(l: ^snap.Exec_Lane, r: Rect) {
	inner_x := r.x + LANE_PAD_X
	inner_w := r.w - 2 * LANE_PAD_X
	y := lane_frame(r, "Execution", l.symbol, false)

	strip_x := inner_x + LANE_DELTA_COL + LANE_DELTA_GAP
	strip_w := inner_w - LANE_DELTA_COL - LANE_DELTA_GAP
	strip_h := glyph_strip_height(l.glyphs, strip_w, 3, .Glance)
	row_h := max(DELTA_ROW_MIN, strip_h)
	draw_lane_delta(format_delta(l.delta), l.delta, inner_x, y + row_h / 2)
	draw_glyph_strip(l.glyphs, strip_x, y + (row_h - strip_h) / 2, strip_w, 3, .Glance)
	y += row_h

	inl, ok := l.inline.?
	if !ok do return
	y += LANE_ROW_GAP
	cy := y + INLINE_ROW_H / 2
	x := inner_x + 88 + 8

	// Before: callee drawn inside its caller's box when it was inlined.
	if inl.was_inlined {
		cw, _ := text_size(.Mono_Regular, 11, inl.caller)
		pw, _ := text_size(.Mono_Regular, 11, inl.callee)
		group := Rect{x, cy - INLINE_ROW_H / 2, 3 + 4 + cw + 4 + 4 + pw + 14 + 3, INLINE_ROW_H}
		stroke_rrect(group, 5, 1, LINE_STRONG)
		draw_text(.Mono_Regular, 11, inl.caller, x + 3 + 4, cy, TEXT_2)
		draw_box_label(inl.callee, x + 3 + 4 + cw + 4 + 4, cy, false)
		x += group.w + 8
	} else {
		x += draw_box_label(inl.caller, x, cy, false) + 8
		arrow(x, cy, 22, GLYPH_FILL)
		x += 22 + 8
		x += draw_box_label(inl.callee, x, cy, false) + 8
	}
	arrow(x, cy, 22, GLYPH_FILL)
	x += 22 + 8

	// After.
	changed := inl.was_inlined != inl.now_inlined
	if inl.now_inlined {
		draw_box_label(fmt.tprintf("%s[%s]", inl.caller, inl.callee), x, cy, changed)
	} else {
		x += draw_box_label(inl.caller, x, cy, false) + 8
		arrow(x, cy, 22, changed ? COST : GLYPH_FILL)
		x += 22 + 8
		draw_box_label(inl.callee, x, cy, changed)
	}
}

MEM_ROW_GAP :: f32(4)
MEM_CELL_H :: f32(14)
MEM_CELL_GAP :: f32(2)
MEM_LABEL_W :: f32(28)

@(private = "file")
draw_memory_lane :: proc(l: ^snap.Memory_Lane, r: Rect) {
	inner_x := r.x + LANE_PAD_X
	inner_w := r.w - 2 * LANE_PAD_X
	y := lane_frame(r, "Memory", l.symbol, false)

	row_h := max(DELTA_ROW_MIN, 2 * MEM_CELL_H + MEM_ROW_GAP)
	draw_lane_delta(format_delta(l.delta, "B"), l.delta, inner_x, y + row_h / 2)

	// Both strips share one cell width so the same byte lines up in each.
	strip_x := inner_x + LANE_DELTA_COL + LANE_DELTA_GAP
	avail := inner_w - LANE_DELTA_COL - LANE_DELTA_GAP - MEM_LABEL_W
	n := max(len(l.old_cells), len(l.new_cells), 1)
	cell_w := min(MEM_CELL_H, (avail - f32(n - 1) * MEM_CELL_GAP) / f32(n))

	top := y + (row_h - (2 * MEM_CELL_H + MEM_ROW_GAP)) / 2
	rows := [2]struct {
		build: snap.Build_Id,
		cells: []snap.Byte_Cell,
		col:   Color,
	}{{l.old_build, l.old_cells, GLYPH_FILL}, {l.new_build, l.new_cells, TEXT_2}}
	for row, i in rows {
		ry := top + f32(i) * (MEM_CELL_H + MEM_ROW_GAP)
		draw_text(.Mono_Regular, 10, fmt.tprintf("%d", row.build), strip_x, ry + MEM_CELL_H / 2, row.col)
		for cell, k in row.cells {
			draw_byte_cell(cell, {strip_x + MEM_LABEL_W + f32(k) * (cell_w + MEM_CELL_GAP), ry, cell_w, MEM_CELL_H}, 2)
		}
	}
}

@(private = "file")
memory_lane_height :: proc(l: ^snap.Memory_Lane) -> f32 {
	if !l.changed do return COLLAPSED_LANE_H
	return LANE_PAD_Y + LINE_H_12 + LANE_ROW_GAP + max(DELTA_ROW_MIN, 2 * MEM_CELL_H + MEM_ROW_GAP) + LANE_PAD_Y
}

ASAN_ROW_H :: f32(15)

@(private = "file")
safety_lane_height :: proc(l: ^snap.Safety_Lane) -> f32 {
	if !l.changed do return COLLAPSED_LANE_H
	h := LANE_PAD_Y + LINE_H_12 + LANE_ROW_GAP + DELTA_ROW_MIN + LANE_PAD_Y
	if l.asan_total > 0 do h += LANE_ROW_GAP + ASAN_ROW_H
	return h
}

@(private = "file")
draw_rings :: proc(items: []snap.Glyph_Item, x, cy: f32) -> f32 {
	cx := x
	for it, i in items {
		if i > 0 do cx += 6
		cx += draw_glyph(it, cx, cy, .Glance)
	}
	return cx - x
}

@(private = "file")
draw_safety_lane :: proc(l: ^snap.Safety_Lane, r: Rect) {
	inner_x := r.x + LANE_PAD_X
	y := lane_frame(r, "Safety", l.symbol, false)

	cy := y + DELTA_ROW_MIN / 2
	draw_lane_delta(format_delta(l.delta), l.delta, inner_x, cy)
	x := inner_x + LANE_DELTA_COL + LANE_DELTA_GAP
	x += draw_rings(l.now, x, cy) + LANE_DELTA_GAP
	// The "after fix" rings only appear when a verified fix exists.
	if len(l.after_fix) > 0 {
		arrow(x, cy, 26, GAIN)
		x += 26 + LANE_DELTA_GAP
		draw_rings(l.after_fix, x, cy)
	}
	y += DELTA_ROW_MIN

	if l.asan_total == 0 do return
	y += LANE_ROW_GAP
	cy = y + ASAN_ROW_H / 2
	x = inner_x + 88 + 8
	x += draw_text(.Mono_Regular, 11, "asan", x, cy, TEXT_3) + 8
	bar := Rect{x, cy - 2, 120, 4}
	fill_rrect(bar, 2, LINE)
	frac := f32(l.asan_done) / f32(l.asan_total)
	if frac > 0 do fill_rrect({bar.x, bar.y, bar.w * frac, bar.h}, 2, TEXT_2)
	draw_text(.Mono_Regular, 11, fmt.tprintf("%d/%d", l.asan_done, l.asan_total), bar.x + bar.w + 8, cy, TEXT_3)
}

// "No change" chips for the quiet signals (`.eq`), then the signals that
// changed with their delta.
@(private = "file")
draw_quiet_chips :: proc(quiet: []string, loud: []snap.Signal_Chip, x, y: f32) -> f32 {
	h := LINE_H_11 + 8
	cx := x
	for l in loud {
		label := fmt.tprintf("%s %s", format_delta(l.delta), l.label)
		tw, _ := text_size(.Mono_Regular, 11, label)
		chip := Rect{cx, y, tw + 16, h}
		fill_rrect(chip, 4, BG_LANE)
		stroke_rrect(chip, 4, 1, delta_color(l.delta))
		draw_text(.Mono_Regular, 11, label, cx + 8, y + h / 2, delta_color(l.delta))
		cx += chip.w + 8
	}
	for q in quiet {
		label := fmt.tprintf("= %s", q)
		tw, _ := text_size(.Mono_Regular, 11, label)
		chip := Rect{cx, y, tw + 16, h}
		fill_rrect(chip, 4, BG_LANE)
		draw_text(.Mono_Regular, 11, label, cx + 8, y + h / 2, TEXT_3)
		cx += chip.w + 8
	}
	return h
}

BUILD_DOT :: f32(8)
BUILD_COL_W :: f32(5 + 8 + 5)
BUILD_COL_H :: f32(6 + 8 + 5 + 8 + 5 + 8 + 6)
LEGEND_H :: f32(15)
FOOTER_H :: f32(12 + BUILD_COL_H + 12 + LEGEND_H + 14)

// Footer: E/M/S dots for the last 16 green builds, then the glyph legend.
@(private = "file")
draw_glance_footer :: proc(m: ^snap.Glance, w, h: f32) {
	top := h - FOOTER_H
	fill_rect({0, top, w, 1}, BG_RAISED)
	y := top + 12
	x := f32(16)

	letters := [3]string{"E", "M", "S"}
	for l, i in letters {
		draw_text(.Mono_Regular, 10, l, x, y + 6 + f32(i) * 13 + BUILD_DOT / 2, TEXT_3)
	}
	x += 7 + 10
	for b in m.builds {
		col := Rect{x, y, BUILD_COL_W, BUILD_COL_H}
		if b.current {
			fill_rrect(col, 4, BG_RAISED)
			stroke_rrect(col, 4, 1, LINE_STRONG)
		}
		dots := [3]snap.Dot{b.e, b.m, b.s}
		for d, i in dots do draw_dot(d, x + BUILD_COL_W / 2, y + 6 + f32(i) * 13 + BUILD_DOT / 2, BUILD_DOT)
		x += BUILD_COL_W + 2
	}

	cy := y + BUILD_COL_H + 12 + LEGEND_H / 2
	x = 16
	legend := [5]struct {
		g:     snap.Glyph,
		label: string,
	}{{.Op, "op"}, {.Mem, "mem"}, {.Branch, "branch"}, {.Call, "call"}, {.Check, "check"}}
	for it in legend {
		x += draw_glyph({it.g, .Plain}, x, cy, .Glance) + 5
		x += draw_text(.Mono_Regular, 11, it.label, x, cy, TEXT_3) + 12
	}
	for d in ([2]struct {
			dot:   snap.Dot,
			label: string,
		}{{.Cost, "cost"}, {.Gain, "gain"}}) {
		draw_dot(d.dot, x + BUILD_DOT / 2, cy, BUILD_DOT)
		x += BUILD_DOT + 5
		x += draw_text(.Mono_Regular, 11, d.label, x, cy, TEXT_3) + 12
	}
}

// The glance body below the tab row (which carries the build status).
draw_glance :: proc(m: ^snap.Glance, top, w, h: f32, mx, my: f32, hits: ^[dynamic]Hit) {
	fill_rect({0, top - 1, w, 1}, BG_RAISED)

	x := f32(12)
	lane_w := w - 24
	y := top + 12
	inner_w := lane_w - 2 * LANE_PAD_X

	lanes := [3]struct {
		h:      f32,
		action: Action,
	}{
		{exec_lane_height(&m.exec, inner_w), .Open_Execution},
		{memory_lane_height(&m.memory), .Open_Memory},
		{safety_lane_height(&m.safety), .Open_Safety},
	}
	for lane, i in lanes {
		r := Rect{x, y, lane_w, lane.h}
		hovered := rect_contains(r, mx, my)
		switch i {
		case 0:
			if m.exec.changed do draw_exec_lane(&m.exec, r)
			else do draw_collapsed_lane(r, "Execution", hovered)
		case 1:
			if m.memory.changed do draw_memory_lane(&m.memory, r)
			else do draw_collapsed_lane(r, "Memory", hovered)
		case 2:
			if m.safety.changed do draw_safety_lane(&m.safety, r)
			else do draw_collapsed_lane(r, "Safety", hovered)
		}
		if hovered do stroke_rrect(r, LANE_RADIUS, 1, LINE_STRONG)
		append(hits, Hit{rect = r, action = lane.action})
		y += lane.h + LANE_GAP
	}

	// The chip row is the next stacked item (gap already added), padded 4 6 0.
	draw_quiet_chips(m.quiet, m.loud, x + 6, y + 4)
	draw_glance_footer(m, w, h)
}
