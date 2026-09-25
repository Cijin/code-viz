package main

import snap "snapshot"

// SPEC §3.2 glyphs. Each proc draws one glyph whose box starts at x and is
// vertically centered on cy, and returns the width it occupies.

Glyph_Scale :: enum u8 {
	Glance,
	Lens,
}

Glyph_Metrics :: struct {
	insn_w, insn_h:  f32, // op / mem
	insn_radius:     f32,
	mem_stroke:      f32,
	branch_side:     f32,
	branch_margin:   f32, // horizontal margin around the rotated square
	call_d:          f32,
	check_d:         f32,
	check_stroke:    f32,
	changed_offset:  f32,
	changed_width:   f32,
}

GLYPH_METRICS := [Glyph_Scale]Glyph_Metrics {
	.Glance = {
		insn_w = 8, insn_h = 14, insn_radius = 1.5, mem_stroke = 1.5,
		branch_side = 8, branch_margin = 2, call_d = 10,
		check_d = 14, check_stroke = 1.5,
		changed_offset = 1, changed_width = 1,
	},
	.Lens = {
		insn_w = 11, insn_h = 20, insn_radius = 2, mem_stroke = 2,
		branch_side = 12, branch_margin = 2, call_d = 15,
		check_d = 18, check_stroke = 2,
		changed_offset = 2, changed_width = 1.5,
	},
}

glyph_width :: proc(glyph: snap.Glyph, scale: Glyph_Scale) -> f32 {
	m := GLYPH_METRICS[scale]
	switch glyph {
	case .Op, .Mem:               return m.insn_w
	case .Branch:                 return m.branch_side + 2 * m.branch_margin
	case .Call:                   return m.call_d
	case .Check, .Check_Removed:  return m.check_d
	}
	return 0
}

// Default colors per glyph (Main.dc.html `.i.*` / `.pp`), before modifiers.
@(private = "file")
glyph_color :: proc(glyph: snap.Glyph, mark: snap.Mark) -> Color {
	#partial switch mark {
	case .New:  return COST
	case .Gain: return GAIN
	}
	switch glyph {
	case .Op:            return GLYPH_FILL
	case .Mem:           return TEXT_2
	case .Branch:        return TEXT_2
	case .Call:          return TEXT
	case .Check:         return TEXT_2
	case .Check_Removed: return TEXT_4
	}
	return TEXT_2
}

draw_glyph :: proc(item: snap.Glyph_Item, x, cy: f32, scale: Glyph_Scale) -> f32 {
	m := GLYPH_METRICS[scale]
	c := glyph_color(item.glyph, item.mark)
	w := glyph_width(item.glyph, scale)
	box: Rect

	switch item.glyph {
	case .Op:
		box = {x, cy - m.insn_h / 2, m.insn_w, m.insn_h}
		fill_rrect(box, m.insn_radius, c)
	case .Mem:
		box = {x, cy - m.insn_h / 2, m.insn_w, m.insn_h}
		stroke_rrect(box, m.insn_radius, m.mem_stroke, c)
	case .Branch:
		cx := x + w / 2
		fill_diamond(cx, cy, m.branch_side, c)
		box = {cx - m.branch_side / 2, cy - m.branch_side / 2, m.branch_side, m.branch_side}
	case .Call:
		fill_circle(x + m.call_d / 2, cy, m.call_d, c)
		box = {x, cy - m.call_d / 2, m.call_d, m.call_d}
	case .Check:
		stroke_circle(x + m.check_d / 2, cy, m.check_d, m.check_stroke, c)
		box = {x, cy - m.check_d / 2, m.check_d, m.check_d}
	case .Check_Removed:
		dashed_circle(x + m.check_d / 2, cy, m.check_d, m.check_stroke, TEXT_4)
		box = {x, cy - m.check_d / 2, m.check_d, m.check_d}
	}

	if item.mark == .Changed {
		dashed_rect(box, m.changed_offset, m.changed_width, TEXT)
	}
	return w
}

// A run of glyphs with a fixed gap; wraps within max_w (flex-wrap). Returns
// the total height used. Row height is the tallest glyph at this scale.
draw_glyph_strip :: proc(items: []snap.Glyph_Item, x, y, max_w, gap: f32, scale: Glyph_Scale) -> f32 {
	row_h := strip_row_height(items, scale)
	cx, cy := x, y + row_h / 2
	rows := 1
	for it in items {
		w := glyph_width(it.glyph, scale)
		if cx > x && cx + w > x + max_w {
			cx = x
			cy += row_h + gap
			rows += 1
		}
		draw_glyph(it, cx, cy, scale)
		cx += w + gap
	}
	return f32(rows) * row_h + f32(rows - 1) * gap
}

// Instruction glyphs are the tallest unless the strip holds check rings.
strip_row_height :: proc(items: []snap.Glyph_Item, scale: Glyph_Scale) -> f32 {
	m := GLYPH_METRICS[scale]
	row_h := m.insn_h
	for it in items do if it.glyph == .Check || it.glyph == .Check_Removed do row_h = max(row_h, m.check_d)
	return row_h
}

glyph_strip_height :: proc(items: []snap.Glyph_Item, max_w, gap: f32, scale: Glyph_Scale) -> f32 {
	row_h := strip_row_height(items, scale)
	cx := f32(0)
	rows := 1
	for it in items {
		w := glyph_width(it.glyph, scale)
		if cx > 0 && cx + w > max_w {
			cx = 0
			rows += 1
		}
		cx += w + gap
	}
	return f32(rows) * row_h + f32(rows - 1) * gap
}

// Memory byte cells (Main.dc.html `.mc`): data, padding (hatched) and
// new data (data fill with a 2 px cost inset).
draw_byte_cell :: proc(cell: snap.Byte_Cell, r: Rect, radius: f32) {
	switch cell {
	case .Data:
		fill_rrect(r, radius, FIELD_FILL)
	case .New_Data:
		fill_rrect(r, radius, FIELD_FILL)
		stroke_rrect(r, radius, 2, COST)
	case .Padding:
		hatch_rect(r, radius)
	}
}

draw_dot :: proc(d: snap.Dot, cx, cy, diameter: f32) {
	c := NEUTRAL_DOT
	switch d {
	case .Cost:    c = COST
	case .Gain:    c = GAIN
	case .Neutral:
	}
	fill_circle(cx, cy, diameter, c)
}

// SPEC §3.2 byte bars (9×18): read = hollow, written = filled; `new` uses
// cost. Returns the width.
MEM_BAR_W :: f32(9)
MEM_BAR_H :: f32(18)

draw_mem_bar :: proc(b: snap.Mem_Bar, x, cy: f32) -> f32 {
	r := Rect{x, cy - MEM_BAR_H / 2, MEM_BAR_W, MEM_BAR_H}
	if b.store {
		fill_rrect(r, 1.5, b.new ? COST : FIELD_FILL)
	} else {
		stroke_rrect(r, 1.5, 1.5, b.new ? COST : TEXT_3)
	}
	return MEM_BAR_W
}
