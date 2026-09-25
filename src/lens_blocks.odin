package main

import "core:fmt"
import "core:strings"
import snap "snapshot"

// Blocks view (SPEC §8.4, Blocks.dc.html): one row per code block, columns
// for execution, safety and memory, and a Σ row. No sentences (§3.4).

BLK_CODE_W :: f32(520)
BLK_SAFETY_W :: f32(150)
BLK_HEAD_H :: f32(40)
BLK_LINE_H :: f32(22)

blk_row_height :: proc(r: ^snap.Block_Row) -> f32 {
	return 20 + BLK_LINE_H * f32(max(len(r.lines), 1))
}

// "·" for an empty column.
@(private = "file")
draw_none :: proc(x, cy: f32) {
	draw_text(.Mono_Regular, 14, "·", x, cy, LINE_STRONG)
}

@(private = "file")
draw_col_delta :: proc(text: string, v: int, right, cy: f32, size := f32(14)) {
	if text == "" do return
	draw_text_right(.Mono_Regular, size, text, right, cy, v < 0 ? GAIN : COST)
}

@(private = "file")
draw_exec_col :: proc(r: ^snap.Block_Row, x, cy, w: f32) {
	if len(r.exec) == 0 && r.callee == "" {
		draw_none(x, cy)
		return
	}
	right := x + w
	delta := r.exec_delta != 0 ? format_delta(r.exec_delta) : ""
	dw, _ := text_size(.Mono_Regular, 14, delta)
	limit := right - dw - 12
	callee := snap.short_name(r.callee)
	cw: f32
	if r.callee != "" {
		tw, _ := text_size(.Mono_Regular, 12, callee)
		cw = 5 + 28 + 5 + tw + 16
		limit -= cw
	}
	cx := x
	for g, i in r.exec {
		gw := glyph_width(g.glyph, .Lens)
		if cx + gw > limit && i < len(r.exec) - 1 {
			cx += draw_text(.Mono_Regular, 11, fmt.tprintf("+%d", len(r.exec) - i), cx, cy, TEXT_3) + 5
			break
		}
		cx += draw_glyph(g, cx, cy, .Lens) + 5
	}
	if r.callee != "" {
		col := r.callee_new ? COST : GLYPH_FILL
		arrow(cx, cy, 28, col)
		cx += 28 + 5
		tw, _ := text_size(.Mono_Regular, 12, callee)
		box := Rect{cx, cy - 11, tw + 16, 22}
		stroke_rrect(box, 4, r.callee_new ? 1.5 : 1, r.callee_new ? COST : LINE_STRONG)
		draw_text(.Mono_Regular, 12, callee, box.x + 8, cy, r.callee_new ? TEXT : TEXT_2)
	}
	draw_col_delta(delta, r.exec_delta, right, cy)
}

@(private = "file")
draw_safety_col :: proc(r: ^snap.Block_Row, x, cy, w: f32) {
	if len(r.checks) == 0 {
		draw_none(x, cy)
		return
	}
	cx := x
	for c in r.checks {
		if cx + 18 > x + w - 30 do break
		cx += draw_glyph(c, cx, cy, .Lens) + 5
	}
	if r.check_delta != 0 do draw_col_delta(format_delta(r.check_delta), r.check_delta, x + w, cy)
}

@(private = "file")
draw_memory_col :: proc(r: ^snap.Block_Row, x, cy, w: f32) {
	right := x + w
	label := r.mem_label
	if label == "" && r.mem_delta != 0 do label = format_delta(r.mem_delta, "B")
	lw, _ := text_size(.Mono_Regular, 14, label)
	limit := right - lw - 12
	cx := x
	switch {
	case len(r.cells) > 0:
		for c, i in r.cells {
			if cx + MEM_BAR_W > limit {
				draw_text(.Mono_Regular, 11, fmt.tprintf("+%d", len(r.cells) - i), cx, cy, TEXT_3)
				break
			}
			draw_byte_cell(c, {cx, cy - MEM_BAR_H / 2, MEM_BAR_W, MEM_BAR_H}, 1.5)
			cx += MEM_BAR_W + 2
		}
	case len(r.bars) > 0:
		for b, i in r.bars {
			if cx + MEM_BAR_W > limit {
				draw_text(.Mono_Regular, 11, fmt.tprintf("+%d", len(r.bars) - i), cx, cy, TEXT_3)
				break
			}
			cx += draw_mem_bar(b, cx, cy) + 2
		}
	case:
		draw_none(x, cy)
	}
	if label != "" {
		col := r.mem_label != "" ? COST : (r.mem_delta < 0 ? GAIN : COST)
		draw_text_right(.Mono_Regular, 14, label, right, cy, col)
	}
}

@(private = "file")
draw_blocks_legend :: proc(y: f32) {
	cy := y + 10
	x := LENS_PAD_X
	glyphs := [5]struct {
		g:     snap.Glyph_Item,
		label: string,
	}{{{.Op, .Plain}, "op"}, {{.Mem, .Plain}, "load / store"}, {{.Branch, .Plain}, "branch"}, {{.Call, .Plain}, "call"}, {{.Check, .Plain}, "check"}}
	for it in glyphs {
		x += draw_glyph(it.g, x, cy, .Lens) + 6
		x += draw_text(.Mono_Regular, 12, it.label, x, cy, TEXT_3) + 18
	}
	x += draw_mem_bar({store = false}, x, cy) + 6
	x += draw_text(.Mono_Regular, 12, "byte read", x, cy, TEXT_3) + 18
	x += draw_mem_bar({store = true}, x, cy) + 6
	x += draw_text(.Mono_Regular, 12, "byte written", x, cy, TEXT_3) + 18
	hatch_rect({x, cy - MEM_BAR_H / 2, MEM_BAR_W, MEM_BAR_H}, 1.5)
	x += MEM_BAR_W + 6
	draw_text(.Mono_Regular, 12, "padding", x, cy, TEXT_3)
}

draw_blocks_view :: proc(win: ^Win, d: ^snap.Delta, hits: ^[dynamic]Hit) {
	b := &d.blocks
	selected := win.pinned >= 0 && win.pinned < len(b.rows) ? win.pinned : b.selected
	file := selected >= 0 ? b.rows[selected].file : ""
	y := draw_lens_top(win, u32(d.from), u32(d.to), file)
	x := LENS_PAD_X
	w := win.w - 2 * LENS_PAD_X

	legend_h := f32(20)
	panel := Rect{x, y, w, win.h - LENS_PAD_BOTTOM - legend_h - LENS_GAP - y}
	draw_card(panel)
	flex := (panel.w - BLK_CODE_W - BLK_SAFETY_W) / 2
	col_exec := panel.x + BLK_CODE_W
	col_safety := col_exec + flex
	col_mem := col_safety + BLK_SAFETY_W
	hy := panel.y + BLK_HEAD_H / 2
	draw_caps("code block", panel.x + 42, hy)
	draw_caps("execution", col_exec + 16, hy)
	draw_caps("safety", col_safety + 16, hy)
	draw_caps("memory", col_mem + 16, hy)

	sum_h := f32(62)
	sum_y := panel.y + panel.h - sum_h
	ry := panel.y + BLK_HEAD_H
	if len(b.rows) == 0 {
		draw_none(panel.x + 42, ry + 21)
	}
	for &row, i in b.rows {
		h := blk_row_height(&row)
		if ry + h > sum_y do break
		rr := Rect{panel.x + 1, ry, panel.w - 2, h}
		fill_rect({rr.x, ry, rr.w, 1}, LINE)
		if i == selected {
			fill_rect(rr, with_alpha(COST, 0.10))
			fill_rect({rr.x, ry, 3, h}, COST)
		} else if row.changed {
			fill_rect(rr, with_alpha(COST, 0.05))
		}
		append(hits, Hit{rr, .Select_Block, i})

		// Source lines.
		ly := ry + 10
		for l in row.lines {
			lcy := ly + BLK_LINE_H / 2
			draw_text(.Mono_Regular, 12.5, fmt.tprintf("%d", l.line), panel.x + 12, lcy, TEXT_4)
			code, _ := strings.replace_all(strings.trim_right_space(l.code), "\t", "    ", context.temp_allocator)
			bright := l.changed && (row.changed || i == selected)
			draw_text(.Mono_Regular, 12.5, fit_text(.Mono_Regular, 12.5, code, BLK_CODE_W - 12 - 30 - 16), panel.x + 12 + 30, lcy, bright ? TEXT : TEXT_3)
			ly += BLK_LINE_H
		}

		// Consequence columns (1 px separators, padding 10×16).
		cy := ry + h / 2
		for cx in ([3]f32{col_exec, col_safety, col_mem}) do fill_rect({cx, ry, 1, h}, LINE)
		draw_exec_col(&row, col_exec + 16, cy, flex - 32)
		draw_safety_col(&row, col_safety + 16, cy, BLK_SAFETY_W - 32)
		draw_memory_col(&row, col_mem + 16, cy, panel.x + panel.w - col_mem - 32)
		ry += h
	}

	// Σ row.
	sr := Rect{panel.x + 1, sum_y, panel.w - 2, sum_h - 1}
	fill_rect(sr, BG_WINDOW)
	fill_rect({sr.x, sum_y, sr.w, 1}, LINE_STRONG)
	scy := sum_y + sum_h / 2
	draw_caps(fmt.tprintf("Σ build %d", d.to), panel.x + 42, scy)
	sums := [3]struct {
		x:    f32,
		v:    int,
		unit: string,
	}{{col_exec + 16, b.sum_exec, ""}, {col_safety + 16, b.sum_checks, ""}, {col_mem + 16, b.sum_mem, "B"}}
	for s in sums {
		fill_rect({s.x - 16, sum_y, 1, sum_h}, LINE)
		draw_text(.Mono_SemiBold, 22, format_delta(s.v, s.unit), s.x, scy, delta_color(s.v))
	}

	draw_blocks_legend(panel.y + panel.h + LENS_GAP)
}
