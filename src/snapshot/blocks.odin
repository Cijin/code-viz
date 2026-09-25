package snapshot

import "core:slice"
import "core:strings"

// SPEC §7.4 / §8.4: one row per code block with its execution, safety and
// memory consequences.

Mem_Bar :: struct {
	store: bool, // byte written (filled) vs read (hollow)
	new:   bool,
}

Block_Line :: struct {
	line:    i32,
	code:    string,
	changed: bool, // new or edited in the source
}

Block_Row :: struct {
	kind:        Block_Kind,
	file:        string,
	first, last: i32,
	owner:       string,
	lines:       []Block_Line,
	exec:        []Glyph_Item,
	exec_delta:  int,
	callee:      string, // project proc this block now calls
	callee_new:  bool,
	checks:      []Glyph_Item,
	check_delta: int,
	cells:       []Byte_Cell, // type declarations
	bars:        []Mem_Bar,   // statements: data bytes read/written
	mem_delta:   int,
	mem_label:   string,
	changed:     bool,
	score:       int,
}

Blocks :: struct {
	rows:       []Block_Row, // source order
	selected:   int,         // auto-pinned: the largest change (§8.6); -1 if none
	sum_exec:   int,
	sum_checks: int,
	sum_mem:    int,
}

// Bytes a load/store instruction moves, whether it stores, and whether it
// addresses the stack frame (spills, which the memory column ignores).
mem_access :: proc(text: string) -> (bytes: int, store, stack, ok: bool) {
	sep := strings.index_any(text, " \t")
	if sep < 0 do return
	m := strings.to_lower(text[:sep], context.temp_allocator)
	ops := strings.trim_space(text[sep:])
	stack = strings.contains(ops, "[sp") || strings.contains(ops, "[x29") || strings.contains(ops, "[rsp") || strings.contains(ops, "[rbp")

	// x86-64 (Intel syntax): the size keyword; a store writes its first operand.
	for kw in ([]struct {
			s: string,
			n: int,
		}{{"byte ptr", 1}, {"word ptr", 2}, {"dword ptr", 4}, {"qword ptr", 8}, {"xmmword ptr", 16}}) {
		if i := strings.index(ops, kw.s); i >= 0 {
			if kw.s == "word ptr" && i > 0 && (ops[i - 1] == 'd' || ops[i - 1] == 'q' || ops[i - 1] == 'm') do continue
			comma := strings.index_byte(ops, ',')
			return kw.n, comma < 0 || i < comma, stack, true
		}
	}

	// arm64.
	is_load := strings.has_prefix(m, "ldr") || strings.has_prefix(m, "ldur") || m == "ldp"
	is_store := strings.has_prefix(m, "str") || strings.has_prefix(m, "stur") || m == "stp"
	if !is_load && !is_store do return
	switch {
	case strings.has_suffix(m, "b") && m != "ldp" && m != "stp":
		bytes = 1
	case strings.has_suffix(m, "h"):
		bytes = 2
	case m == "ldrsw":
		bytes = 4
	case:
		reg := ops
		if c := strings.index_byte(ops, ','); c > 0 do reg = ops[:c]
		reg = strings.trim_space(reg)
		switch reg[0] {
		case 'w', 's': bytes = 4
		case 'x', 'd': bytes = 8
		case 'q':      bytes = 16
		case 'b':      bytes = 1
		case 'h':      bytes = 2
		case:          bytes = 8
		}
		if m == "ldp" || m == "stp" do bytes *= 2
	}
	return bytes, is_store, stack, true
}

@(private = "file")
Pos_Key :: struct {
	file: string,
	line: i32,
}

// The project proc named in a call's asm text, e.g. `bl 0x.. <_frame::x>`.
@(private = "file")
asm_callee :: proc(text: string) -> string {
	a := strings.index_byte(text, '<')
	b := strings.last_index_byte(text, '>')
	if a < 0 || b <= a do return ""
	t := strings.trim_prefix(text[a + 1:b], "_")
	if plus := strings.last_index_byte(t, '+'); plus > 0 do t = t[:plus]
	return t
}

build_blocks :: proc(prev, curr: ^Snapshot, d: ^Delta, allocator := context.allocator) -> Blocks {
	out := Blocks{selected = -1}

	// Changed source lines: new, or paired with an edited previous line.
	changed_src := make(map[Pos_Key]bool, allocator = context.temp_allocator)
	for file, lines in curr.source {
		old, had := prev.source[file]
		if !had do continue
		pairs := pair_lines(old, lines, context.temp_allocator)
		for ln := 1; ln <= len(lines); ln += 1 {
			p := pairs[ln]
			if p == 0 || old[p - 1] != lines[ln - 1] do changed_src[{file, i32(ln)}] = true
		}
	}

	exec_rows := make(map[Pos_Key]^Line_Row, allocator = context.temp_allocator)
	return_size := make(map[string]int, allocator = context.temp_allocator)
	for &pd in d.procs {
		return_size[pd.symbol] = pd.new_return_size
		for &r in pd.rows do if r.line > 0 do exec_rows[{r.file, r.line}] = &r
	}
	safety_lines := make(map[Pos_Key]^Safety_Line, allocator = context.temp_allocator)
	for &ps in d.safety.procs do for &l in ps.lines do safety_lines[{ps.file, l.line}] = &l

	rows := make([dynamic]Block_Row, context.temp_allocator)
	for b in curr.blocks {
		row := Block_Row{kind = b.kind, file = b.file, first = b.first, last = b.last, owner = b.owner}
		src := curr.source[b.file]
		lines := make([dynamic]Block_Line, allocator)
		exec := make([dynamic]Glyph_Item, allocator)
		checks := make([dynamic]Glyph_Item, allocator)
		bars := make([dynamic]Mem_Bar, allocator)
		old_bytes, new_bytes := 0, 0

		for ln := b.first; ln <= b.last; ln += 1 {
			code := int(ln) <= len(src) ? src[ln - 1] : ""
			ch := changed_src[{b.file, ln}]
			append(&lines, Block_Line{line = ln, code = strings.clone(code, allocator), changed = ch})
			if ch do row.changed = true
			if b.kind == .Type_Decl do continue

			if r, ok := exec_rows[{b.file, ln}]; ok {
				append(&exec, ..r.now)
				row.exec_delta += r.delta
				for g in r.now do if g.mark != .Plain do row.changed = true
				for text, i in r.now_asm {
					is_new := i < len(r.now) && r.now[i].mark == .New
					if n, store, stack, mok := mem_access(text); mok && !stack {
						new_bytes += n
						for _ in 0 ..< n do append(&bars, Mem_Bar{store = store, new = is_new})
					}
					if row.callee == "" {
						if c := asm_callee(text); c != "" && c in curr.procs && c != b.owner {
							row.callee = strings.clone(c, allocator)
							row.callee_new = is_new
						}
					}
				}
				for text in r.old_asm {
					if n, _, stack, mok := mem_access(text); mok && !stack do old_bytes += n
				}
			}
			if sl, ok := safety_lines[{b.file, ln}]; ok {
				for c in sl.checks {
					append(&checks, c)
					if c.mark == .New do row.check_delta += 1
				}
			}
		}

		if b.kind == .Type_Decl {
			for td in d.types {
				t, ok := td.new.?
				if !ok || t.name != b.owner do continue
				row.cells = byte_cells(t, td.new_fields, allocator)
				row.mem_delta = td.size_delta
				if td.size_delta != 0 do row.changed = true
			}
		} else {
			row.mem_delta = new_bytes - old_bytes
			// A large aggregate return is written through the hidden result
			// pointer into the caller's frame (docs/VERIFIED.md §6).
			first_code := len(lines) > 0 ? strings.trim_space(lines[0].code) : ""
			if strings.has_prefix(first_code, "return") && return_size[b.owner] > 16 && len(bars) > 0 {
				row.mem_label = "stack"
			}
		}

		if row.exec_delta != 0 || row.check_delta != 0 || row.mem_delta != 0 do row.changed = true
		row.exec = exec[:]
		row.checks = checks[:]
		row.bars = bars[:]
		row.lines = lines[:]
		row.score = abs(row.exec_delta) + abs(row.check_delta) + abs(row.mem_delta)
		row.file = strings.clone(row.file, allocator)
		row.owner = strings.clone(row.owner, allocator)
		append(&rows, row)
	}

	// Changed blocks, plus the other statements of procedures with a change,
	// in source order (Blocks.dc.html).
	touched := make(map[string]bool, allocator = context.temp_allocator)
	for r in rows do if r.changed && r.kind == .Statement do touched[r.owner] = true
	kept := make([dynamic]Block_Row, allocator)
	for r in rows do if r.changed || (r.kind == .Statement && touched[r.owner]) do append(&kept, r)
	slice.sort_by(kept[:], proc(a, b: Block_Row) -> bool {
		if a.file != b.file do return strings.compare(a.file, b.file) < 0
		return a.first < b.first
	})

	best := 0
	for r, i in kept {
		out.sum_exec += r.exec_delta
		out.sum_checks += r.check_delta
		if r.kind == .Type_Decl do out.sum_mem += r.mem_delta
		if r.changed && r.score > best {
			best = r.score
			out.selected = i
		}
	}
	out.rows = kept[:]
	return out
}
