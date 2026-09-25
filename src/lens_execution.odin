package main

import "core:fmt"
import "core:strings"
import snap "snapshot"

// Execution lens (SPEC §8.5, Execution.dc.html).

EXEC_ROW_H :: f32(40)
EXEC_HEAD_H :: f32(30)
EXEC_COL_N :: f32(44)
EXEC_COL_CODE :: f32(400)
EXEC_COL_D :: f32(56)

@(private = "file")
arch_label :: proc() -> string {
	return ODIN_ARCH == .arm64 ? "arm64" : "x86-64"
}

// SPEC §3.3 lens stat box: glyph, big delta, old→new.
@(private = "file")
draw_stat_box :: proc(glyph: snap.Glyph, old, new: int, right, cy: f32) -> f32 {
	d := new - old
	delta := format_delta(d)
	sub := fmt.tprintf("%d→%d", old, new)
	dw, _ := text_size(.Mono_SemiBold, 22, delta)
	sw, _ := text_size(.Mono_Regular, 13, sub)
	gw := glyph_width(glyph, .Lens)
	w := 14 + gw + 10 + dw + 10 + sw + 14
	r := Rect{right - w, cy - 20, w, 40}
	fill_rrect(r, 6, BG_PANEL)
	stroke_rrect(r, 6, 1, LINE)
	x := r.x + 14
	x += draw_glyph({glyph, d != 0 ? .New : .Plain}, x, cy, .Lens) + 10
	x += draw_text(.Mono_SemiBold, 22, delta, x, cy, delta_color(d)) + 10
	draw_text(.Mono_Regular, 13, sub, x, cy, TEXT_3)
	return w
}

// Glyph cells, or the instruction text when "show asm" is on. Clips to `w`
// and says how many were left out.
@(private = "file")
draw_cells :: proc(glyphs: []snap.Glyph_Item, texts: []string, show_asm: bool, x, cy, w: f32) {
	if show_asm {
		line := strings.join(texts, "; ", context.temp_allocator)
		draw_text(.Mono_Regular, 11, fit_text(.Mono_Regular, 11, line, w), x, cy, TEXT_2)
		return
	}
	cx := x
	for g, i in glyphs {
		gw := glyph_width(g.glyph, .Lens)
		if cx + gw > x + w - 28 && i < len(glyphs) - 1 {
			draw_text(.Mono_Regular, 11, fmt.tprintf("+%d", len(glyphs) - i), cx, cy, TEXT_3)
			return
		}
		cx += draw_glyph(g, cx, cy, .Lens) + 5
	}
}

@(private = "file")
draw_exec_rows :: proc(win: ^Win, pd: ^snap.Proc_Delta, from, to: snap.Build_Id, r: Rect) {
	draw_card(r)
	x := r.x + 16
	cell_w := (r.w - 32 - EXEC_COL_N - EXEC_COL_CODE - EXEC_COL_D) / 2
	col_old := x + EXEC_COL_N + EXEC_COL_CODE
	col_new := col_old + cell_w
	right := r.x + r.w - 16

	hy := r.y + 8 + EXEC_HEAD_H / 2
	draw_caps(fmt.tprintf("%d", from), col_old, hy)
	draw_caps(fmt.tprintf("%d", to), col_new, hy, TEXT)
	draw_text_right(.Sans_SemiBold, CAPS_SIZE, "Δ", right, hy, TEXT_3)

	y := r.y + 8 + EXEC_HEAD_H
	for row in pd.rows {
		if y + EXEC_ROW_H > r.y + r.h - 4 do break
		rr := Rect{r.x + 1, y, r.w - 2, EXEC_ROW_H}
		fill_rect({rr.x + 15, y, rr.w - 30, 1}, LINE)
		if row.changed do fill_rect(rr, with_alpha(COST, 0.07))
		cy := y + EXEC_ROW_H / 2

		label := row.cold ? "cold" : (row.line > 0 ? fmt.tprintf("%d", row.line) : fmt.tprintf("−%d", row.old_line))
		draw_text(.Mono_Regular, 12, label, x, cy, row.changed ? COST : TEXT_4)
		code := row.cold ? "check failure paths" : strings.trim_right_space(row.code)
		code, _ = strings.replace_all(code, "\t", "    ", context.temp_allocator)
		draw_text(.Mono_Regular, 12.5, fit_text(.Mono_Regular, 12.5, code, EXEC_COL_CODE - 12), x + EXEC_COL_N, cy, row.changed ? TEXT : TEXT_3)

		draw_cells(row.old, row.old_asm, win.show_asm, col_old, cy, cell_w - 8)
		draw_cells(row.now, row.now_asm, win.show_asm, col_new, cy, cell_w - 8)
		if row.delta != 0 do draw_text_right(.Mono_Regular, 14, format_delta(row.delta), right, cy, delta_color(row.delta))
		y += EXEC_ROW_H
	}
}

@(private = "file")
draw_inline_panel :: proc(d: ^snap.Delta, pd: ^snap.Proc_Delta, r: Rect) {
	draw_card(r)
	x := r.x + 16
	y := r.y + 16
	draw_caps("Inline", x, y + 8)
	y += 16 + 14

	change: Maybe(snap.Inline_Change)
	for ic in d.inline do if ic.caller == pd.symbol || ic.callee == pd.symbol {
		change = ic
		break
	}
	ic, ok := change.?
	if !ok {
		draw_text(.Mono_Regular, 12, "=", x, y + 12, TEXT_3)
		return
	}
	caller, callee := snap.short_name(ic.caller), snap.short_name(ic.callee)
	rows := [2]struct {
		build:   snap.Build_Id,
		inlined: bool,
		col:     Color,
	}{{d.from, ic.was_inlined, TEXT_4}, {d.to, ic.now_inlined, TEXT_2}}
	for row, i in rows {
		cy := y + 14
		lx := x + 32 + 12
		draw_text(.Mono_Regular, 11, fmt.tprintf("%d", row.build), x, cy, row.col)
		hot := i == 1
		if row.inlined {
			cw, _ := text_size(.Mono_Regular, 12, caller)
			pw, _ := text_size(.Mono_Regular, 12, callee)
			group := Rect{lx, cy - 16, 10 + cw + 6 + pw + 20 + 4, 32}
			stroke_rrect(group, 6, 1, LINE_STRONG)
			draw_text(.Mono_Regular, 12, caller, lx + 10, cy, TEXT_2)
			box := Rect{lx + 10 + cw + 6, cy - 13, pw + 20, 26}
			stroke_rrect(box, 5, hot ? 1.5 : 1, hot ? COST : LINE_STRONG)
			draw_text(.Mono_Regular, 12, callee, box.x + 10, cy, hot ? TEXT : TEXT_2)
		} else {
			cw, _ := text_size(.Mono_Regular, 12, caller)
			box := Rect{lx, cy - 13, cw + 20, 26}
			stroke_rrect(box, 5, 1, LINE_STRONG)
			draw_text(.Mono_Regular, 12, caller, box.x + 10, cy, TEXT_2)
			ax := box.x + box.w + 8
			arrow(ax, cy, 28, hot ? COST : GLYPH_FILL)
			pw, _ := text_size(.Mono_Regular, 12, callee)
			pbox := Rect{ax + 28 + 8, cy - 13, pw + 20, 26}
			stroke_rrect(pbox, 5, hot ? 1.5 : 1, hot ? COST : LINE_STRONG)
			draw_text(.Mono_Regular, 12, callee, pbox.x + 10, cy, hot ? TEXT : TEXT_2)
		}
		y += 28 + 14
	}
}

// Return-value ABI: small aggregates come back in registers; larger ones go
// through a hidden result pointer (docs/VERIFIED.md §6).
@(private = "file")
draw_return_panel :: proc(d: ^snap.Delta, pd: ^snap.Proc_Delta, r: Rect) {
	draw_card(r)
	x := r.x + 16
	y := r.y + 16
	rtype := pd.return_type != "" ? snap.short_name(pd.return_type) : "—"
	draw_caps(fmt.tprintf("Return · %s", rtype), x, y + 8)
	y += 16 + 16
	if pd.new_return_size == 0 && pd.old_return_size == 0 do return

	regs := ODIN_ARCH == .arm64 ? [2]string{"x0", "x1"} : [2]string{"rax", "rdx"}
	hidden := ODIN_ARCH == .arm64 ? "x8" : "rdi"
	rows := [2]struct {
		build: snap.Build_Id,
		size:  int,
		col:   Color,
	}{{d.from, pd.old_return_size, TEXT_4}, {d.to, pd.new_return_size, TEXT_2}}
	changed := pd.old_return_size != pd.new_return_size
	for row, i in rows {
		if row.size == 0 do continue
		cy := y + 15
		draw_text(.Mono_Regular, 11, fmt.tprintf("%d", row.build), x, cy, row.col)
		sx := x + 32 + 12
		if row.size <= 16 {
			for reg in regs {
				slot := Rect{sx, cy - 15, 92, 30}
				fill_rrect(slot, 4, LINE_STRONG)
				tw, _ := text_size(.Mono_Regular, 11, reg)
				draw_text(.Mono_Regular, 11, reg, slot.x + (slot.w - tw) / 2, cy, TEXT)
				sx += 92 + 4
			}
		} else {
			slot := Rect{sx, cy - 15, 60, 30}
			fill_rrect(slot, 4, LINE_STRONG)
			tw, _ := text_size(.Mono_Regular, 11, hidden)
			draw_text(.Mono_Regular, 11, hidden, slot.x + (slot.w - tw) / 2, cy, TEXT)
			sx += 60 + 8
			hot := i == 1 && changed
			arrow(sx, cy, 36, hot ? COST : GLYPH_FILL)
			sx += 36 + 8
			label := fmt.tprintf("stack · %d B", row.size)
			lw, _ := text_size(.Mono_Regular, 11, label)
			box := Rect{sx, cy - 15, lw + 24, 30}
			stroke_rrect(box, 4, hot ? 1.5 : 1, hot ? COST : LINE_STRONG)
			draw_text(.Mono_Regular, 11, label, box.x + 12, cy, hot ? COST : TEXT_2)
			sx += box.w
		}
		size_col := i == 1 && changed ? delta_color(pd.new_return_size - pd.old_return_size) : TEXT_2
		draw_text(.Mono_Regular, 13, fmt.tprintf("%d B", row.size), sx + 12, cy, size_col)
		y += 30 + 16
	}
}

// T2 scenario (SPEC §6.9, M6). Callgrind runs on Linux only.
@(private = "file")
draw_scenario_panel :: proc(r: Rect) {
	draw_card(r)
	x := r.x + 16
	y := r.y + 16
	draw_caps("Scenario", x, y + 8)
	draw_text_right(.Mono_Regular, 11, "callgrind", r.x + r.w - 16, y + 8, TEXT_4)
	draw_text(.Mono_Regular, 12, ODIN_OS == .Linux ? "—" : "linux only", x, y + 16 + 14 + 8, TEXT_3)
}

@(private = "file")
draw_exec_legend :: proc(win: ^Win, y: f32, hits: ^[dynamic]Hit) {
	cy := y + 22
	x := LENS_PAD_X
	items := [6]struct {
		g:     snap.Glyph_Item,
		label: string,
	}{
		{{.Op, .Plain}, "op"},
		{{.Mem, .Plain}, "load / store"},
		{{.Branch, .Plain}, "branch"},
		{{.Call, .Plain}, "call / ret"},
		{{.Op, .New}, "new"},
		{{.Mem, .Changed}, "changed"},
	}
	for it in items {
		x += draw_glyph(it.g, x, cy, .Lens) + 6
		x += draw_text(.Mono_Regular, 12, it.label, x, cy, TEXT_3) + 20
	}
	label := win.show_asm ? "show glyphs" : "show asm"
	lw, _ := text_size(.Mono_Regular, 12, label)
	b := Rect{win.w - LENS_PAD_X - lw - 32, y, lw + 32, 44}
	hovered := rect_contains(b, win.mouse_x, win.mouse_y)
	fill_rrect(b, 6, hovered ? BG_RAISED : BG_LANE)
	stroke_rrect(b, 6, 1, LINE_STRONG)
	draw_text(.Mono_Regular, 12, label, b.x + 16, cy, TEXT_2)
	append(hits, Hit{b, .Toggle_Asm})
}

draw_execution_lens :: proc(win: ^Win, d: ^snap.Delta, hits: ^[dynamic]Hit) {
	y := draw_lens_top(win, u32(d.from), u32(d.to), fmt.tprintf("-o:minimal · %s", arch_label()))
	if len(d.procs) == 0 {
		draw_lens_empty(win, y, "No code")
		return
	}
	pd := &d.procs[0]
	x := LENS_PAD_X
	w := win.w - 2 * LENS_PAD_X

	cy := y + 20
	draw_text(.Mono_SemiBold, LENS_TITLE, snap.short_name(pd.symbol), x, cy, TEXT)
	right := x + w
	right -= draw_stat_box(.Call, pd.old_kinds[.Call], pd.new_kinds[.Call], right, cy) + 10
	right -= draw_stat_box(.Branch, pd.old_kinds[.Branch], pd.new_kinds[.Branch], right, cy) + 10
	draw_stat_box(.Op, pd.old_count, pd.new_count, right, cy)
	y += 40 + LENS_GAP

	legend_h := f32(44)
	bottom_h := f32(230)
	rows_h := win.h - LENS_PAD_BOTTOM - legend_h - LENS_GAP - bottom_h - LENS_GAP - y
	needed := 8 + EXEC_HEAD_H + f32(len(pd.rows)) * EXEC_ROW_H + 4
	rows_h = min(rows_h, needed)
	draw_exec_rows(win, pd, d.from, d.to, {x, y, w, rows_h})
	y += rows_h + LENS_GAP

	bottom_h = win.h - LENS_PAD_BOTTOM - legend_h - LENS_GAP - y
	pw := (w - 2 * 16) / 3
	draw_inline_panel(d, pd, {x, y, pw, bottom_h})
	draw_return_panel(d, pd, {x + pw + 16, y, pw, bottom_h})
	draw_scenario_panel({x + 2 * (pw + 16), y, pw, bottom_h})
	y += bottom_h + LENS_GAP

	draw_exec_legend(win, y, hits)
}
