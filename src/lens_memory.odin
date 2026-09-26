package main

import "core:fmt"
import "core:strings"
import snap "snapshot"

// Memory lens (SPEC §8.5, Memory.dc.html).

@(private = "file")
Layout_Card :: struct {
	label:     string,
	t:         snap.Type_Layout,
	color:     Color,
	outline:   Color,
	outline_w: f32,
	new_names: []string, // fields drawn with the cost inset
	moved:     []string, // fields drawn with the gain inset
}

GRID_ROW_H :: f32(56)
GRID_GAP :: f32(4)
GRID_OFFS_W :: f32(24)

@(private = "file")
grid_rows :: proc(t: snap.Type_Layout) -> int {
	return max((t.size + 7) / 8, 1)
}

@(private = "file")
card_height :: proc(t: snap.Type_Layout) -> f32 {
	rows := f32(grid_rows(t))
	return 16 + 28 + 14 + 8 + 14 + rows * GRID_ROW_H + (rows - 1) * GRID_GAP + 16
}

@(private = "file")
contains :: proc(list: []string, s: string) -> bool {
	for x in list do if x == s do return true
	return false
}

// One run of a field or padding within a single grid row.
@(private = "file")
draw_grid_span :: proc(r: Rect, name, size_label: string, padding, is_new, moved: bool) {
	if padding {
		hatch_rect(r, 4)
		tw, _ := text_size(.Mono_SemiBold, 13, size_label)
		tag := Rect{r.x + r.w - 6 - tw - 8, r.y + r.h - 6 - 18, tw + 8, 18}
		fill_rrect(tag, 2, BG_PANEL)
		draw_text(.Mono_SemiBold, 13, size_label, tag.x + 4, tag.y + 9, COST)
		return
	}
	fill_rrect(r, 4, LINE)
	switch {
	case is_new: stroke_rrect(r, 4, 2, COST)
	case moved:  stroke_rrect(r, 4, 2, GAIN)
	case:        stroke_rrect(r, 4, 1, LINE_STRONG)
	}
	if name != "" {
		draw_text(.Mono_Regular, 13, fit_text(.Mono_Regular, 13, name, r.w - 12), r.x + 6, r.y + 6 + 9, TEXT)
		draw_text(.Mono_Regular, 11, size_label, r.x + 6, r.y + r.h - 6 - 8, TEXT_3)
	}
}

// Truncates to fit `max_w`, keeping the start.
fit_text :: proc(face: Face, size: f32, s: string, max_w: f32) -> string {
	w, _ := text_size(face, size, s)
	if w <= max_w do return s
	for n := len(s) - 1; n > 0; n -= 1 {
		cand := s[:n]
		cw, _ := text_size(face, size, cand)
		if cw <= max_w do return cand
	}
	return ""
}

@(private = "file")
draw_layout_card :: proc(c: Layout_Card, r: Rect) {
	draw_card(r, c.outline, c.outline_w)
	x := r.x + 16
	w := r.w - 32
	y := r.y + 16

	draw_text(.Mono_Regular, 13, c.label, x, y + 14, c.color)
	draw_text_right(.Mono_Regular, 22, fmt.tprintf("%d B", c.t.size), x + w, y + 14, c.color)
	y += 28 + 14

	// Density bar: data share, then hatched padding.
	data := c.t.size - snap.padding_bytes(c.t)
	frac := c.t.size > 0 ? f32(data) / f32(c.t.size) : 1
	fill_rrect({x, y, (w - 2) * frac, 8}, 2, TEXT_3)
	if frac < 1 do hatch_rect({x + (w - 2) * frac + 2, y, (w - 2) * (1 - frac), 8}, 2)
	y += 8 + 14

	// Byte grid: 8 columns; offsets on the left. Clipped to the card, which
	// may be shorter than the type.
	push_clip({r.x, y, r.w, r.y + r.h - 16 - y})
	defer pop_clip()
	gx := x + GRID_OFFS_W + 8
	gw := w - GRID_OFFS_W - 8
	col_w := (gw - 7 * GRID_GAP) / 8
	rows := grid_rows(c.t)
	for row in 0 ..< rows {
		draw_text(.Mono_Regular, 11, fmt.tprintf("%d", row * 8), x, y + f32(row) * (GRID_ROW_H + GRID_GAP) + GRID_ROW_H / 2, TEXT_4)
	}

	Span :: struct {
		first, count: int,
		name:         string,
		size:         int,
		padding:      bool,
	}
	spans := make([dynamic]Span, context.temp_allocator)
	cursor := 0
	for f in c.t.fields {
		if f.offset > cursor do append(&spans, Span{cursor, f.offset - cursor, "", f.offset - cursor, true})
		append(&spans, Span{f.offset, f.size, f.name, f.size, false})
		cursor = max(cursor, f.offset + f.size)
	}
	if c.t.size > cursor do append(&spans, Span{cursor, c.t.size - cursor, "", c.t.size - cursor, true})

	for sp in spans {
		// Split a span at row boundaries; label only its first piece.
		b := sp.first
		first_piece := true
		for b < sp.first + sp.count {
			row := b / 8
			col := b % 8
			n := min(8 - col, sp.first + sp.count - b)
			cell := Rect{
				gx + f32(col) * (col_w + GRID_GAP),
				y + f32(row) * (GRID_ROW_H + GRID_GAP),
				f32(n) * col_w + f32(n - 1) * GRID_GAP,
				GRID_ROW_H,
			}
			draw_grid_span(cell, first_piece ? sp.name : "", fmt.tprintf("%d", sp.size), sp.padding,
				contains(c.new_names, sp.name), contains(c.moved, sp.name))
			first_piece = false
			b += n
		}
	}
}

// "Frame_Header" -> "H", "headers": the element label and plural in the
// cache-line strip.
@(private = "file")
element_words :: proc(name: string) -> (letter, plural: string) {
	last := name
	if i := strings.last_index_byte(name, '_'); i >= 0 && i + 1 < len(name) do last = name[i + 1:]
	letter = strings.to_upper(last[:1], context.temp_allocator)
	plural = fmt.tprintf("%ss", strings.to_lower(last, context.temp_allocator))
	return
}

SEG_PX_PER_BYTE :: f32(8) // 64 B line = 512 px

@(private = "file")
draw_placement :: proc(label: string, color: Color, size: int, letter: string, x, y: f32) -> f32 {
	p := snap.placement(size, context.temp_allocator)
	lines := p.lines
	block_h := f32(lines) * 34 + f32(lines - 1) * 4
	draw_text(.Mono_Regular, 13, label, x, y + block_h / 2, color)
	lx := x + 40 + 20
	for line in 0 ..< lines {
		ly := y + f32(line) * (34 + 4)
		draw_text(.Mono_Regular, 11, fmt.tprintf("%d", line), lx, ly + 17, TEXT_4)
		bx := lx + 20 + 12
		lo, hi := line * snap.CACHE_LINE, (line + 1) * snap.CACHE_LINE
		for e in 0 ..< snap.PLACEMENT_ELEMS {
			start, end := e * size, (e + 1) * size
			a, b := max(start, lo), min(end, hi)
			if a >= b do continue
			seg := Rect{bx + f32(a - lo) * SEG_PX_PER_BYTE, ly, f32(b - a) * SEG_PX_PER_BYTE, 34}
			split := contains_int(p.spanning, e)
			fill_rect(seg, split ? with_alpha(COST, 0.22) : LINE)
			stroke_rrect(seg, 0, split ? 1.5 : 1, split ? COST : BG_DESKTOP)
			tag := fmt.tprintf("%s%d", letter, e)
			tw, _ := text_size(.Mono_Regular, 11, tag)
			if tw < seg.w do draw_text(.Mono_Regular, 11, tag, seg.x + (seg.w - tw) / 2, ly + 17, split ? COST : TEXT_2)
		}
	}
	cx := lx + 20 + 12 + 512 + 20
	draw_text(.Mono_SemiBold, 28, fmt.tprintf("%d", lines), cx, y + block_h / 2 - 8, color)
	draw_text(.Mono_Regular, 11, "lines", cx, y + block_h / 2 + 16, TEXT_3)
	return block_h
}

@(private = "file")
contains_int :: proc(list: []int, v: int) -> bool {
	for x in list do if x == v do return true
	return false
}

@(private = "file")
format_kb_delta :: proc(bytes: int) -> string {
	kb := f32(abs(bytes)) / 1000
	sign := bytes > 0 ? "+" : (bytes < 0 ? "−" : "")
	if kb == f32(int(kb)) do return fmt.tprintf("%s%d KB", sign, int(kb))
	return fmt.tprintf("%s%.1f KB", sign, kb)
}

@(private = "file")
draw_totals_bars :: proc(label, delta_text: string, delta_col: Color, values: []int, colors: []Color, x, y, w: f32) -> f32 {
	draw_text(.Mono_Regular, 12, label, x, y + 8, TEXT_2)
	draw_text_right(.Mono_Regular, 12, delta_text, x + w, y + 8, delta_col)
	by := y + 16 + 6
	top := 0
	for v in values do top = max(top, v)
	for v, i in values {
		frac := top > 0 ? f32(v) / f32(top) : 0
		fill_rrect({x, by, w * frac, 14}, 2, colors[i])
		by += 14 + 6
	}
	return 16 + 6 + f32(len(values)) * 20 - 6
}

draw_memory_lens :: proc(win: ^Win, d: ^snap.Delta) {
	y := draw_lens_top(win, u32(d.from), u32(d.to), "DWARF")
	if len(d.types) == 0 {
		draw_lens_empty(win, y, "No type changes")
		return
	}
	td := d.types[0]
	new_t, has_new := td.new.?
	old_t, has_old := td.old.?
	fix_t, has_fix := td.suggested.?
	if !has_new {
		draw_lens_empty(win, y, "Type removed")
		return
	}
	x := LENS_PAD_X
	w := win.w - 2 * LENS_PAD_X

	// Title row: name, order and alignment chips, size change.
	cy := y + 20
	tx := x + draw_text(.Mono_SemiBold, LENS_TITLE, snap.short_name(td.name), x, cy, TEXT) + 14
	tx += draw_chip(has_fix ? "declared order" : "packed", tx, cy + 4) + 14
	draw_chip(fmt.tprintf("align %d", new_t.align), tx, cy + 4)
	right := x + w
	grew := td.size_delta > 0
	right -= draw_text_right(.Mono_SemiBold, LENS_TITLE, fmt.tprintf("%d B", new_t.size), right, cy, delta_color(td.size_delta)) + 12
	if has_old && td.size_delta != 0 {
		arrow(right - 28, cy, 28, delta_color(td.size_delta))
		right -= 28 + 12
		draw_text_right(.Mono_Regular, 22, fmt.tprintf("%d B", old_t.size), right, cy + 2, TEXT_3)
	}
	y += 40 + LENS_GAP

	// Layout cards: before, after, suggested fix.
	cards := make([dynamic]Layout_Card, context.temp_allocator)
	if has_old do append(&cards, Layout_Card{fmt.tprintf("%d", d.from), old_t, TEXT_3, LINE, 1, nil, nil})
	append(&cards, Layout_Card{fmt.tprintf("%d", d.to), new_t, grew ? COST : TEXT, grew ? COST : LINE, grew ? 1.5 : 1, td.new_fields, nil})
	if has_fix do append(&cards, Layout_Card{"fix", fix_t, GAIN, LINE, 1, nil, td.moved})
	card_w := (w - 2 * 16) / 3
	card_h := f32(0)
	for c in cards do card_h = max(card_h, card_height(c.t))
	// Large types are taller than the window: cap the cards (their grids are
	// clipped) so the cache-line and totals section below always fits.
	LOWER_MIN_H :: f32(260)
	card_h = min(card_h, max(win.h - LENS_PAD_BOTTOM - LOWER_MIN_H - LENS_GAP - y, 160))
	for c, i in cards do draw_layout_card(c, {x + f32(i) * (card_w + 16), y, card_w, card_h})
	y += card_h + LENS_GAP

	// Bottom: cache-line placement (left) and 10,000-element totals (right).
	bottom_h := win.h - LENS_PAD_BOTTOM - y
	right_w := f32(440)
	left := Rect{x, y, w - right_w - 16, bottom_h}
	draw_card(left)
	letter, plural := element_words(snap.short_name(td.name))
	draw_caps(fmt.tprintf("64 B cache lines · %d %s", snap.PLACEMENT_ELEMS, plural), left.x + 16, left.y + 16 + 8)
	py := left.y + 16 + 16 + 22
	Placement_Row :: struct {
		label: string,
		col:   Color,
		size:  int,
	}
	placements := make([dynamic]Placement_Row, context.temp_allocator)
	if has_fix {
		append(&placements, Placement_Row{fmt.tprintf("%d", d.to), grew ? COST : TEXT, new_t.size})
		append(&placements, Placement_Row{"fix", GAIN, fix_t.size})
	} else {
		if has_old do append(&placements, Placement_Row{fmt.tprintf("%d", d.from), TEXT_3, old_t.size})
		append(&placements, Placement_Row{fmt.tprintf("%d", d.to), grew ? COST : TEXT, new_t.size})
	}
	for pl in placements {
		py += draw_placement(pl.label, pl.col, pl.size, letter, left.x + 16, py) + 22
	}

	rc := Rect{left.x + left.w + 16, y, right_w, bottom_h}
	draw_card(rc)
	ix, iw := rc.x + 16, rc.w - 32
	ry := rc.y + 16
	draw_caps(fmt.tprintf("[dynamic]%s × 10,000", snap.short_name(td.name)), ix, ry + 8)
	draw_text_right(.Mono_Regular, 11, "dwarf", ix + iw, ry + 8, TEXT_4)
	ry += 16 + 18

	ob, ol := snap.array_totals(has_old ? old_t.size : new_t.size)
	nb, nl := snap.array_totals(new_t.size)
	fb, fl := snap.array_totals(has_fix ? fix_t.size : new_t.size)
	bytes_vals := [3]int{ob, nb, fb}
	line_vals := [3]int{ol, nl, fl}
	bar_cols := [3]Color{FIELD_FILL, delta_color(nb - ob) == TEXT_3 ? FIELD_FILL : delta_color(nb - ob), GAIN}
	n := has_fix ? 3 : 2
	ry += draw_totals_bars("bytes", format_kb_delta(nb - ob), delta_color(nb - ob), bytes_vals[:n], bar_cols[:n], ix, ry, iw) + 18
	pct := ol > 0 ? (nl - ol) * 100 / ol : 0
	pct_text := pct > 0 ? fmt.tprintf("+%d%%", pct) : (pct < 0 ? fmt.tprintf("−%d%%", -pct) : "=")
	ry += draw_totals_bars("cache lines", pct_text, delta_color(pct), line_vals[:n], bar_cols[:n], ix, ry, iw) + 18

}
