package main

import "core:fmt"
import "core:strings"
import snap "snapshot"

// Safety lens (SPEC §8.5, Safety.dc.html). Only measured facts are shown:
// the mockup's "fix" column needs a verified rewrite, which v1 does not
// generate, and "can wrap" has no analyzer yet.

SAFETY_LINE_H :: f32(34)

@(private = "file")
draw_rung :: proc(r: Rect, label, total: string, hot: bool) {
	draw_card(r, hot ? COST : LINE, hot ? 1.5 : 1)
	draw_caps(label, r.x + 16, r.y + 16 + 8)
	if total != "" do draw_text_right(.Mono_Regular, 12, total, r.x + r.w - 16, r.y + 16 + 8, TEXT_4)
}

@(private = "file")
checkmark :: proc(x, y: f32, c: Color) {
	// `M2 11l8 8L26 3` at 2.5 px.
	line(x + 2, y + 11, x + 10, y + 19, 2.5, c)
	line(x + 10, y + 19, x + 26, y + 3, 2.5, c)
}

// Opt-outs inside the proc's source lines.
@(private = "file")
proc_opt_outs :: proc(sd: ^snap.Safety_Delta, ps: ^snap.Proc_Safety) -> int {
	if len(ps.lines) == 0 do return 0
	first, last := ps.lines[0].line, ps.lines[len(ps.lines) - 1].line
	n := 0
	for o in sd.opt_outs do if o.pos.file == ps.file && o.pos.line >= first && o.pos.line <= last do n += 1
	return n
}

draw_safety_lens :: proc(win: ^Win, d: ^snap.Delta) {
	y := draw_lens_top(win, u32(d.from), u32(d.to), "-o:minimal")
	sd := &d.safety
	if len(sd.procs) == 0 {
		draw_lens_empty(win, y, "No check sites")
		return
	}
	ps := &sd.procs[0]
	x := LENS_PAD_X
	w := win.w - 2 * LENS_PAD_X

	// Title and the check-site stat.
	cy := y + 20
	draw_text(.Mono_SemiBold, LENS_TITLE, snap.short_name(ps.symbol), x, cy, TEXT)
	{
		dv := ps.new_active - ps.old_active
		delta := format_delta(dv)
		sub := fmt.tprintf("%d→%d", ps.old_active, ps.new_active)
		dw, _ := text_size(.Mono_SemiBold, 22, delta)
		sw, _ := text_size(.Mono_Regular, 13, sub)
		bw := 14 + 18 + 10 + dw + 10 + sw + 14
		r := Rect{x + w - bw, cy - 20, bw, 40}
		fill_rrect(r, 6, BG_PANEL)
		stroke_rrect(r, 6, 1, LINE)
		bx := r.x + 14
		bx += draw_glyph({.Check, dv > 0 ? .New : .Plain}, bx, cy, .Lens) + 10
		bx += draw_text(.Mono_SemiBold, 22, delta, bx, cy, delta_color(dv)) + 10
		draw_text(.Mono_Regular, 13, sub, bx, cy, TEXT_3)
	}
	y += 40 + LENS_GAP

	// Rungs: compiler, run-time checks, opt-outs, can wrap.
	rung_w := (w - 3 * 16) / 4
	rung_h := f32(16 + 16 + 14 + 22 + 16)
	pkg_delta := sd.total_new - sd.total_old
	rungs_y := y
	draw_rung({x, rungs_y, rung_w, rung_h}, "Compiler", "all", false)
	checkmark(x + 16, rungs_y + 16 + 16 + 14, TEXT_2)

	r2 := Rect{x + rung_w + 16, rungs_y, rung_w, rung_h}
	total := fmt.tprintf("pkg %d", sd.total_new)
	draw_rung(r2, "Run-time check", "", ps.changed)
	tw := draw_text_right(.Mono_Regular, 12, pkg_delta != 0 ? format_delta(pkg_delta) : "", r2.x + r2.w - 16, r2.y + 24, delta_color(pkg_delta))
	draw_text_right(.Mono_Regular, 12, total, r2.x + r2.w - 16 - (tw > 0 ? tw + 6 : 0), r2.y + 24, TEXT_4)
	rx := r2.x + 16
	for l in ps.lines do for ring in l.checks do if ring.glyph == .Check {
		if rx + 18 > r2.x + r2.w - 16 do break
		rx += draw_glyph(ring, rx, r2.y + 16 + 16 + 14 + 11, .Lens) + 8
	}

	r3 := Rect{x + 2 * (rung_w + 16), rungs_y, rung_w, rung_h}
	draw_rung(r3, "Opted out", fmt.tprintf("pkg %d", sd.opt_outs_new), sd.opt_outs_new != sd.opt_outs_old)
	draw_text(.Mono_Regular, 22, fmt.tprintf("%d", proc_opt_outs(sd, ps)), r3.x + 16, r3.y + 16 + 16 + 14 + 11, TEXT_4)

	r4 := Rect{x + 3 * (rung_w + 16), rungs_y, rung_w, rung_h}
	draw_rung(r4, "Can wrap", "", false)
	draw_text(.Mono_Regular, 22, "—", r4.x + 16, r4.y + 16 + 16 + 14 + 11, TEXT_4)
	y += rung_h + LENS_GAP

	// Source with a ring per check site.
	footer_h := f32(44)
	panel := Rect{x, y, w, win.h - LENS_PAD_BOTTOM - footer_h - LENS_GAP - y}
	draw_card(panel)
	px_ := panel.x + 16
	py := panel.y + 16
	draw_text(.Mono_Regular, 13, fmt.tprintf("%d", d.to), px_, py + 10, ps.changed ? COST : TEXT_2)
	draw_text_right(.Mono_SemiBold, 22, fmt.tprintf("%d", ps.new_active), panel.x + panel.w - 16, py + 10, ps.changed ? COST : TEXT)
	py += 20 + 14
	for l in ps.lines {
		if py + SAFETY_LINE_H > panel.y + panel.h - 8 do break
		row := Rect{panel.x + 1, py, panel.w - 2, SAFETY_LINE_H}
		if l.hot do fill_rect(row, with_alpha(COST, 0.10))
		lcy := py + SAFETY_LINE_H / 2
		draw_text(.Mono_Regular, 12.5, fmt.tprintf("%d", l.line), px_, lcy, l.hot ? COST : TEXT_4)
		mx := px_ + 30
		for ring, i in l.checks {
			if i > 0 do mx += 4
			mx += draw_glyph(ring, mx + (i == 0 && len(l.checks) == 1 ? 6 : 0), lcy, .Lens)
		}
		code, _ := strings.replace_all(strings.trim_right_space(l.code), "\t", "    ", context.temp_allocator)
		draw_text(.Mono_Regular, 12.5, fit_text(.Mono_Regular, 12.5, code, panel.w - 32 - 30 - 60), px_ + 30 + 60, lcy, l.hot ? TEXT : TEXT_3)
		py += SAFETY_LINE_H
	}
	y = panel.y + panel.h + LENS_GAP

	// Footer: sanitizer (T2, M6), vet (T1), legend.
	fcy := y + footer_h / 2
	fx := x
	{
		label := "asan · odin test"
		lw, _ := text_size(.Mono_Regular, 12, label)
		r := Rect{fx, y, 14 + lw + 12 + 180 + 12 + 30 + 14, footer_h}
		fill_rrect(r, 6, BG_PANEL)
		stroke_rrect(r, 6, 1, LINE)
		bx := fx + 14 + draw_text(.Mono_Regular, 12, label, fx + 14, fcy, TEXT_2) + 12
		fill_rrect({bx, fcy - 3, 180, 6}, 3, LINE)
		draw_text(.Mono_Regular, 12, "—", bx + 180 + 12, fcy, TEXT_3)
		fx += r.w + 16
	}
	{
		vet_text := "…"
		vet_col := TEXT_3
		if sd.vet_ready {
			n := len(sd.vet_new)
			vet_text = n > 0 ? format_delta(n) : fmt.tprintf("= %d", sd.vet_total)
			vet_col = n > 0 ? COST : TEXT_3
		}
		vw, _ := text_size(.Mono_Regular, 14, vet_text)
		lw, _ := text_size(.Mono_Regular, 12, "vet")
		r := Rect{fx, y, 14 + lw + 10 + vw + 14, footer_h}
		fill_rrect(r, 6, BG_PANEL)
		stroke_rrect(r, 6, 1, LINE)
		draw_text(.Mono_Regular, 12, "vet", fx + 14, fcy, TEXT_2)
		draw_text(.Mono_Regular, 14, vet_text, fx + 14 + lw + 10, fcy, vet_col)
	}
	// Legend, right-aligned.
	items := [3]struct {
		g:     snap.Glyph_Item,
		label: string,
	}{{{.Check, .Plain}, "check"}, {{.Check, .New}, "new"}, {{.Check_Removed, .Plain}, "removed by optimizer"}}
	lx := x + w
	#reverse for it in items {
		tw2, _ := text_size(.Mono_Regular, 12, it.label)
		lx -= tw2
		draw_text(.Mono_Regular, 12, it.label, lx, fcy, TEXT_3)
		lx -= 6 + 14
		draw_glyph(it.g, lx, fcy, .Glance)
		lx -= 18
	}
}
