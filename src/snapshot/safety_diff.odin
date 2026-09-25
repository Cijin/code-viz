package snapshot

import "core:slice"
import "core:strings"

// Safety lane and lens data (SPEC §6.4, §6.5): run-time check sites per
// line, optimizer-removed checks, and opt-outs.

Vet_Finding :: struct {
	pos:     Source_Pos,
	message: string,
}

Safety_Line :: struct {
	line:    i32,
	code:    string,
	checks:  []Glyph_Item, // active (plain/new) then removed rings
	hot:     bool,         // gained a check
}

Proc_Safety :: struct {
	symbol:      string,
	file:        string,
	old_active:  int,
	new_active:  int,
	new_removed: int,
	lines:       []Safety_Line, // the proc's source lines, declaration to end
	changed:     bool,
}

Safety_Delta :: struct {
	procs:        []Proc_Safety, // changed first
	total_old:    int, // active check sites, whole project
	total_new:    int,
	opt_outs_old: int,
	opt_outs_new: int,
	opt_outs:     []Opt_Out, // current build
	stack_delta:  int, // frame bytes, procs in both builds
	vet_total:    int, // filled by the T1 vet result
	vet_new:      []Vet_Finding,
	vet_ready:    bool,
}

@(private = "file")
Key :: struct {
	file: string,
	line: i32,
}

@(private = "file")
count_active :: proc(checks: []Check_Site) -> int {
	n := 0
	for c in checks do if !c.removed do n += 1
	return n
}

// Last source line of the proc declared at `start` (matching braces).
@(private = "file")
proc_end :: proc(lines: []string, start: i32) -> i32 {
	depth := 0
	opened := false
	for i := int(start) - 1; i < len(lines); i += 1 {
		depth += strings.count(lines[i], "{") - strings.count(lines[i], "}")
		if strings.contains(lines[i], "{") do opened = true
		if opened && depth <= 0 do return i32(i + 1)
	}
	return i32(len(lines))
}

diff_safety :: proc(prev, curr: ^Snapshot, allocator := context.allocator) -> Safety_Delta {
	sd := Safety_Delta{
		total_old    = count_active(prev.checks),
		total_new    = count_active(curr.checks),
		opt_outs_old = len(prev.opt_outs),
		opt_outs_new = len(curr.opt_outs),
	}
	for sym, pc in curr.procs do if old, ok := prev.procs[sym]; ok do sd.stack_delta += pc.stack - old.stack
	sd.opt_outs = make([]Opt_Out, len(curr.opt_outs), allocator)
	for o, i in curr.opt_outs {
		sd.opt_outs[i] = o
		sd.opt_outs[i].pos.file = strings.clone(o.pos.file, allocator)
	}

	pairs := make(map[string][]i32, allocator = context.temp_allocator)
	for file, lines in curr.source {
		if old, ok := prev.source[file]; ok do pairs[file] = pair_lines(old, lines, context.temp_allocator)
	}
	old_by_line := make(map[Key]int, allocator = context.temp_allocator)
	for c in prev.checks do if !c.removed do old_by_line[{c.pos.file, c.pos.line}] += 1

	per_proc := make(map[string][dynamic]Check_Site, allocator = context.temp_allocator)
	for c in curr.checks {
		list := per_proc[c.proc_]
		if list.allocator.procedure == nil do list.allocator = context.temp_allocator
		append(&list, c)
		per_proc[c.proc_] = list
	}
	old_per_proc := make(map[string]int, allocator = context.temp_allocator)
	for c in prev.checks do if !c.removed do old_per_proc[c.proc_] += 1

	out := make([dynamic]Proc_Safety, allocator)
	for sym, checks in per_proc {
		pc, emitted := curr.procs[sym]
		if !emitted do continue
		ps := Proc_Safety{
			symbol     = strings.clone(sym, allocator),
			file       = strings.clone(pc.pos.file, allocator),
			old_active = old_per_proc[sym],
			new_active = count_active(checks[:]),
		}
		for c in checks do if c.removed do ps.new_removed += 1

		// Rings per current line; a line gains `new` rings beyond the count on
		// its paired previous line.
		by_line := make(map[i32][dynamic]Check_Site, allocator = context.temp_allocator)
		for c in checks {
			list := by_line[c.pos.line]
			if list.allocator.procedure == nil do list.allocator = context.temp_allocator
			append(&list, c)
			by_line[c.pos.line] = list
		}
		src := curr.source[pc.pos.file]
		start := pc.pos.line
		end := start > 0 ? proc_end(src, start) : 0
		lines := make([dynamic]Safety_Line, allocator)
		for ln := start; ln >= 1 && ln <= end && int(ln) <= len(src); ln += 1 {
			sl := Safety_Line{line = ln, code = strings.clone(src[ln - 1], allocator)}
			old_count := 0
			if p, ok := pairs[pc.pos.file]; ok && int(ln) < len(p) && p[ln] > 0 {
				old_count = old_by_line[{pc.pos.file, p[ln]}]
			}
			rings := make([dynamic]Glyph_Item, allocator)
			active := 0
			// Copy out first: ranging over `by_line[ln]` directly takes the
			// address of a missing key's value, which is nil.
			on_line := by_line[ln]
			for c in on_line do if !c.removed {
				active += 1
				mark := active > old_count ? Mark.New : Mark.Plain
				if mark == .New do sl.hot = true
				append(&rings, Glyph_Item{.Check, mark})
			}
			for c in on_line do if c.removed do append(&rings, Glyph_Item{.Check_Removed, .Plain})
			sl.checks = rings[:]
			append(&lines, sl)
		}
		ps.lines = lines[:]
		ps.changed = ps.new_active != ps.old_active
		for l in ps.lines do if l.hot do ps.changed = true
		append(&out, ps)
	}
	slice.sort_by(out[:], proc(a, b: Proc_Safety) -> bool {
		if a.changed != b.changed do return a.changed
		da, db := abs(a.new_active - a.old_active), abs(b.new_active - b.old_active)
		if da != db do return da > db
		return strings.compare(a.symbol, b.symbol) < 0
	})
	sd.procs = out[:]
	return sd
}

// New vet findings: messages not reported for the same file before (line
// numbers move with edits, so they are not part of the match).
new_vet_findings :: proc(prev, curr: []Vet_Finding, allocator := context.allocator) -> []Vet_Finding {
	seen := make(map[[2]string]int, allocator = context.temp_allocator)
	for f in prev do seen[{f.pos.file, f.message}] += 1
	out := make([dynamic]Vet_Finding, allocator)
	for f in curr {
		k := [2]string{f.pos.file, f.message}
		if seen[k] > 0 {
			seen[k] -= 1
			continue
		}
		append(&out, Vet_Finding{pos = {file = strings.clone(f.pos.file, allocator), line = f.pos.line}, message = strings.clone(f.message, allocator)})
	}
	return out[:]
}
