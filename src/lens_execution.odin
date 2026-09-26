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

// A lens stat box: label, delta, old→new.
@(private = "file")
draw_count_box :: proc(label: string, old, new: int, right, cy: f32, big := false) -> f32 {
	d := new - old
	delta := format_delta(d)
	sub := fmt.tprintf("%d\u2192%d", old, new)
	dsize := big ? f32(22) : f32(16)
	dface := big ? Face.Mono_SemiBold : Face.Mono_Regular
	lw, _ := text_size(.Mono_Regular, 13, label)
	dw, _ := text_size(dface, dsize, delta)
	sw, _ := text_size(.Mono_Regular, 13, sub)
	w := 14 + lw + 10 + dw + 10 + sw + 14
	r := Rect{right - w, cy - 20, w, 40}
	fill_rrect(r, 6, BG_PANEL)
	stroke_rrect(r, 6, 1, LINE)
	x := r.x + 14
	x += draw_text(.Mono_Regular, 13, label, x, cy, TEXT_3) + 10
	x += draw_text(dface, dsize, delta, x, cy, delta_color(d)) + 10
	draw_text(.Mono_Regular, 13, sub, x, cy, TEXT_3)
	return w
}

// Instruction text for display: a space instead of the tab (the font has
// no glyph for it), and no absolute address where a <symbol> names the
// target, since addresses move on every relink.
@(private = "file")
asm_display :: proc(text: string) -> string {
	s, _ := strings.replace_all(text, "\t", " ", context.temp_allocator)
	if lt := strings.index(s, " <"); lt >= 0 {
		start := strings.last_index(s[:lt], "0x")
		if start >= 0 && !strings.contains(s[start:lt], " ") {
			s = strings.concatenate({s[:start], s[lt + 1:]}, context.temp_allocator)
		}
	}
	s, _ = strings.replace_all(s, "<_", "<", context.temp_allocator)
	return s
}

// Diff colour: new = cost, removed (old side) = gain, changed = bright,
// same = dim.
@(private = "file")
mark_color :: proc(m: snap.Mark) -> Color {
	switch m {
	case .New:     return COST
	case .Gain:    return GAIN
	case .Changed: return TEXT
	case .Plain:
	}
	return TEXT_3
}

ASM_SIZE :: f32(11.5)
ASM_LINE_H :: f32(17)
ASM_MAX_LINES :: 8
ASM_GAP :: f32(14) // between instructions on a line

Asm_Seg :: struct {
	text: string,
	col:  Color,
	x:    f32, // offset within the cell
	line: int,
}

// Lays a line's instructions out in rows of the cell width, breaking between
// instructions. Past ASM_MAX_LINES the rest is counted as "+N".
@(private = "file")
layout_asm :: proc(marks: []snap.Glyph_Item, texts: []string, w: f32) -> (segs: [dynamic]Asm_Seg, lines: int) {
	segs = make([dynamic]Asm_Seg, context.temp_allocator)
	if len(texts) == 0 do return
	x := f32(0)
	line := 0
	for text, i in texts {
		t := asm_display(text)
		tw, _ := text_size(.Mono_Regular, ASM_SIZE, t)
		if x > 0 && x + tw > w {
			line += 1
			x = 0
		}
		if line == ASM_MAX_LINES - 1 && i < len(texts) - 1 {
			// Last visible line: keep room for the "+N" count.
			more := fmt.tprintf("+%d", len(texts) - i)
			mw, _ := text_size(.Mono_Regular, ASM_SIZE, more)
			if x + tw + ASM_GAP + mw > w {
				append(&segs, Asm_Seg{more, TEXT_4, x, line})
				return segs, line + 1
			}
		}
		if tw > w do t = fit_text(.Mono_Regular, ASM_SIZE, t, w)
		mark := i < len(marks) ? marks[i].mark : snap.Mark.Plain
		append(&segs, Asm_Seg{t, mark_color(mark), x, line})
		x += tw + ASM_GAP
	}
	return segs, line + 1
}

@(private = "file")
draw_asm :: proc(segs: []Asm_Seg, x, top: f32) {
	for s in segs {
		draw_text(.Mono_Regular, ASM_SIZE, s.text, x + s.x, top + f32(s.line) * ASM_LINE_H + ASM_LINE_H / 2, s.col)
	}
}

@(private = "file")
exec_row_height :: proc(old_lines, new_lines: int) -> f32 {
	return max(EXEC_ROW_H, 11 + f32(max(old_lines, new_lines, 1)) * ASM_LINE_H + 11)
}

@(private = "file")
exec_cell_width :: proc(w: f32) -> f32 {
	return (w - 32 - EXEC_COL_N - EXEC_COL_CODE - EXEC_COL_D) / 2
}

// Height the rows need at this width.
@(private = "file")
exec_rows_height :: proc(pd: ^snap.Proc_Delta, w: f32) -> f32 {
	cw := exec_cell_width(w) - 16
	h := 8 + EXEC_HEAD_H + 4
	for row in pd.rows {
		_, ol := layout_asm(row.old, row.old_asm, cw)
		_, nl := layout_asm(row.now, row.now_asm, cw)
		h += exec_row_height(ol, nl)
	}
	return h
}

@(private = "file")
draw_exec_rows :: proc(pd: ^snap.Proc_Delta, from, to: snap.Build_Id, r: Rect) {
	draw_card(r)
	x := r.x + 16
	cell_w := exec_cell_width(r.w)
	col_old := x + EXEC_COL_N + EXEC_COL_CODE
	col_new := col_old + cell_w
	right := r.x + r.w - 16

	hy := r.y + 8 + EXEC_HEAD_H / 2
	draw_caps(fmt.tprintf("build %d", from), col_old, hy)
	draw_caps(fmt.tprintf("build %d", to), col_new, hy, TEXT)
	draw_text_right(.Sans_SemiBold, CAPS_SIZE, "\u0394", right, hy, TEXT_3)

	y := r.y + 8 + EXEC_HEAD_H
	for row in pd.rows {
		old_segs, ol := layout_asm(row.old, row.old_asm, cell_w - 16)
		new_segs, nl := layout_asm(row.now, row.now_asm, cell_w - 16)
		h := exec_row_height(ol, nl)
		if y + h > r.y + r.h - 4 do break
		rr := Rect{r.x + 1, y, r.w - 2, h}
		fill_rect({rr.x + 15, y, rr.w - 30, 1}, LINE)
		if row.changed do fill_rect(rr, with_alpha(COST, 0.07))
		// Source and delta align with the first line of instructions.
		top := y + 11
		cy := top + ASM_LINE_H / 2

		label := row.cold ? "cold" : (row.line > 0 ? fmt.tprintf("%d", row.line) : fmt.tprintf("\u2212%d", row.old_line))
		draw_text(.Mono_Regular, 12, label, x, cy, row.changed ? COST : TEXT_4)
		code := row.cold ? "check failure paths" : strings.trim_right_space(row.code)
		code, _ = strings.replace_all(code, "\t", "    ", context.temp_allocator)
		draw_text(.Mono_Regular, 12.5, fit_text(.Mono_Regular, 12.5, code, EXEC_COL_CODE - 12), x + EXEC_COL_N, cy, row.changed ? TEXT : TEXT_3)

		draw_asm(old_segs[:], col_old, top)
		draw_asm(new_segs[:], col_new, top)
		if row.delta != 0 do draw_text_right(.Mono_Regular, 14, format_delta(row.delta), right, cy, delta_color(row.delta))
		y += h
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

// Colour key for the instruction text.
@(private = "file")
draw_exec_legend :: proc(y: f32) {
	cy := y + 22
	x := LENS_PAD_X
	items := [4]struct {
		mark:  snap.Mark,
		label: string,
	}{{.New, "new"}, {.Gain, "removed"}, {.Changed, "changed opcode"}, {.Plain, "same"}}
	for it in items {
		fill_rrect({x, cy - 5, 10, 10}, 2, mark_color(it.mark))
		x += 10 + 6
		x += draw_text(.Mono_Regular, 12, it.label, x, cy, TEXT_3) + 20
	}
}

draw_execution_lens :: proc(win: ^Win, d: ^snap.Delta) {
	y := draw_lens_top(win, u32(d.from), u32(d.to), fmt.tprintf("-o:minimal \u00b7 %s", arch_label()))
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
	right -= draw_count_box("spills", pd.old_spills, pd.new_spills, right, cy) + 10
	right -= draw_count_box("call", pd.old_kinds[.Call], pd.new_kinds[.Call], right, cy) + 10
	right -= draw_count_box("branch", pd.old_kinds[.Branch], pd.new_kinds[.Branch], right, cy) + 10
	draw_count_box("instr", pd.old_count, pd.new_count, right, cy, big = true)
	y += 40 + LENS_GAP

	legend_h := f32(44)
	bottom_h := f32(230)
	rows_h := win.h - LENS_PAD_BOTTOM - legend_h - LENS_GAP - bottom_h - LENS_GAP - y
	rows_h = min(rows_h, exec_rows_height(pd, w))
	draw_exec_rows(pd, d.from, d.to, {x, y, w, rows_h})
	y += rows_h + LENS_GAP

	bottom_h = win.h - LENS_PAD_BOTTOM - legend_h - LENS_GAP - y
	pw := (w - 2 * 16) / 3
	draw_inline_panel(d, pd, {x, y, pw, bottom_h})
	draw_return_panel(d, pd, {x + pw + 16, y, pw, bottom_h})
	draw_scenario_panel({x + 2 * (pw + 16), y, pw, bottom_h})
	y += bottom_h + LENS_GAP

	draw_exec_legend(y)
}
