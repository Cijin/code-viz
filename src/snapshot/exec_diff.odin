package snapshot

import "core:slice"
import "core:strings"

// SPEC §7.2: per-line instruction diff, keyed through the line mapping so an
// edit above a procedure doesn't make every row look changed.

Line_Row :: struct {
	file:     string,
	line:     i32, // current line; 0 for a removed line or the cold row
	old_line: i32, // paired previous line; 0 for a new line
	code:     string,
	old:      []Glyph_Item,
	now:      []Glyph_Item,
	old_asm:  []string,
	now_asm:  []string,
	delta:    int,
	changed:  bool,
	cold:     bool,
}

Proc_Delta :: struct {
	symbol:          string,
	file:            string,
	old_count:       int,
	new_count:       int,
	old_kinds:       [Insn_Kind]int,
	new_kinds:       [Insn_Kind]int,
	rows:            []Line_Row,
	glyphs:          []Glyph_Item, // every current instruction, with marks
	changed:         bool,
	is_new:          bool,
	removed:         bool,
	return_type:     string,
	old_return_size: int,
	new_return_size: int,
	old_spills:      int, // stack loads/stores, left out of the rows
	new_spills:      int,
}

// Loads and stores that address the stack frame are register spills: at
// -o:minimal nearly every value takes one, and they bury the instructions
// that do the line's work. The rows leave them out and count them instead.
is_spill :: proc(insn: Insn) -> bool {
	if insn.kind != .Mem do return false
	_, _, stack, ok := mem_access(insn.text)
	return ok && stack
}

@(private = "file")
without_spills :: proc(insns: []Insn) -> (work: []Insn, spills: int) {
	out := make([dynamic]Insn, context.temp_allocator)
	for insn in insns {
		if is_spill(insn) {
			spills += 1
			continue
		}
		append(&out, insn)
	}
	return out[:], spills
}

// The mnemonic alone: a different register or stack offset is not a
// changed instruction.
@(private = "file")
mnemonic_of :: proc(text: string) -> string {
	if sep := strings.index_any(text, " \t"); sep >= 0 do return text[:sep]
	return text
}

glyph_of :: proc(k: Insn_Kind) -> Glyph {
	switch k {
	case .Op:     return .Op
	case .Mem:    return .Mem
	case .Branch: return .Branch
	case .Call:   return .Call
	}
	return .Op
}

// Share of characters in the common prefix and suffix of two lines.
@(private = "file")
similarity :: proc(a, b: string) -> f32 {
	x, y := strings.trim_space(a), strings.trim_space(b)
	if len(x) == 0 || len(y) == 0 do return 0
	p := 0
	for p < len(x) && p < len(y) && x[p] == y[p] do p += 1
	s := 0
	for s < len(x) - p && s < len(y) - p && x[len(x) - 1 - s] == y[len(y) - 1 - s] do s += 1
	return f32(p + s) / f32(max(len(x), len(y)))
}

PAIR_SIMILARITY :: 0.5

// new line -> old line: unchanged lines from the Myers map, then each edited
// new line paired with the most similar edited old line in the same gap.
pair_lines :: proc(old, new: []string, allocator := context.allocator) -> []i32 {
	lm := map_lines(old, new, context.temp_allocator)
	pairs := slice.clone(lm.new_to_old, allocator)
	used := make([]bool, len(old) + 1, context.temp_allocator)
	for o in lm.new_to_old do if o > 0 do used[o] = true

	for nl := 1; nl <= len(new); nl += 1 {
		if pairs[nl] != 0 do continue
		// The gap: old lines between the mapped neighbours of this line.
		lo, hi := 0, len(old) + 1
		for p := nl - 1; p >= 1; p -= 1 do if lm.new_to_old[p] != 0 {lo = int(lm.new_to_old[p]); break}
		for p := nl + 1; p <= len(new); p += 1 do if lm.new_to_old[p] != 0 {hi = int(lm.new_to_old[p]); break}
		best, best_s := 0, f32(PAIR_SIMILARITY)
		for ol := lo + 1; ol < hi; ol += 1 {
			if used[ol] do continue
			if s := similarity(old[ol - 1], new[nl - 1]); s > best_s do best, best_s = ol, s
		}
		if best > 0 {
			pairs[nl] = i32(best)
			used[best] = true
		}
	}
	return pairs
}

// Matches by kind, in order: the longest common subsequence of kinds, so a
// reordered spill doesn't read as removed + new. Unmatched current = new;
// matched with other operands = changed; unmatched old = removed (counted,
// not drawn).
@(private = "file")
diff_line :: proc(old, now: []Insn, allocator := context.allocator) -> (old_g, now_g: []Glyph_Item, removed: int, changed: bool) {
	old_g = make([]Glyph_Item, len(old), allocator)
	now_g = make([]Glyph_Item, len(now), allocator)
	for insn, i in old do old_g[i] = {glyph_of(insn.kind), .Plain}

	// lcs[i][j] = LCS length of old[i:] and now[j:].
	w := len(now) + 1
	lcs := make([]int, (len(old) + 1) * w, context.temp_allocator)
	for i := len(old) - 1; i >= 0; i -= 1 {
		for j := len(now) - 1; j >= 0; j -= 1 {
			if old[i].kind == now[j].kind {
				lcs[i * w + j] = lcs[(i + 1) * w + j + 1] + 1
			} else {
				lcs[i * w + j] = max(lcs[(i + 1) * w + j], lcs[i * w + j + 1])
			}
		}
	}
	i, j := 0, 0
	for j < len(now) {
		if i < len(old) && old[i].kind == now[j].kind && lcs[i * w + j] == lcs[(i + 1) * w + j + 1] + 1 {
			mark := Mark.Plain
			if mnemonic_of(old[i].text) != mnemonic_of(now[j].text) {
				mark = .Changed
				changed = true
			}
			now_g[j] = {glyph_of(now[j].kind), mark}
			i += 1
			j += 1
		} else if i < len(old) && lcs[(i + 1) * w + j] >= lcs[i * w + j + 1] {
			removed += 1
			i += 1
		} else {
			now_g[j] = {glyph_of(now[j].kind), .New}
			changed = true
			j += 1
		}
	}
	removed += len(old) - i
	if removed > 0 do changed = true
	return
}

@(private = "file")
Line_Key :: struct {
	file: string,
	line: i32,
}

@(private = "file")
group_by_line :: proc(insns: []Insn, allocator := context.temp_allocator) -> (lines: map[Line_Key][dynamic]Insn, order: [dynamic]Line_Key, cold: [dynamic]Insn) {
	lines = make(map[Line_Key][dynamic]Insn, allocator = allocator)
	order = make([dynamic]Line_Key, allocator)
	cold = make([dynamic]Insn, allocator)
	for insn in insns {
		if insn.cold {
			append(&cold, insn)
			continue
		}
		key := Line_Key{insn.pos.file, insn.pos.line}
		if key not_in lines {
			lines[key] = make([dynamic]Insn, allocator)
			append(&order, key)
		}
		list := lines[key]
		append(&list, insn)
		lines[key] = list
	}
	return
}

@(private = "file")
source_line :: proc(src: map[string][]string, file: string, line: i32) -> string {
	lines, ok := src[file]
	if !ok || line < 1 || int(line) > len(lines) do return ""
	return lines[line - 1]
}

@(private = "file")
asm_texts :: proc(insns: []Insn, allocator := context.allocator) -> []string {
	out := make([]string, len(insns), allocator)
	for insn, i in insns do out[i] = strings.clone(insn.text, allocator)
	return out
}

// `pairs[file]` maps current -> previous lines (pair_lines).
diff_proc :: proc(prev, curr: ^Snapshot, symbol: string, pairs: map[string][]i32, allocator := context.allocator) -> Proc_Delta {
	pd := Proc_Delta{symbol = strings.clone(symbol, allocator)}
	old_code, had := prev.procs[symbol]
	new_code, has := curr.procs[symbol]
	pd.is_new = !had
	pd.removed = !has
	old_work, old_spills := without_spills(old_code.insns)
	new_work, new_spills := without_spills(new_code.insns)
	pd.old_spills, pd.new_spills = old_spills, new_spills
	pd.old_count, pd.new_count = len(old_work), len(new_work)
	for insn in old_work do pd.old_kinds[insn.kind] += 1
	for insn in new_work do pd.new_kinds[insn.kind] += 1
	pd.old_return_size, pd.new_return_size = old_code.return_size, new_code.return_size
	pd.return_type = strings.clone(new_code.return_type != "" ? new_code.return_type : old_code.return_type, allocator)

	old_lines, old_order, old_cold := group_by_line(old_work)
	new_lines, new_order, new_cold := group_by_line(new_work)
	if len(new_order) > 0 do pd.file = strings.clone(new_order[0].file, allocator)
	else if len(old_order) > 0 do pd.file = strings.clone(old_order[0].file, allocator)

	rows := make([dynamic]Line_Row, allocator)
	glyphs := make([dynamic]Glyph_Item, allocator)
	used_old := make(map[Line_Key]bool, allocator = context.temp_allocator)

	// Current lines in source order.
	slice.sort_by(new_order[:], proc(a, b: Line_Key) -> bool {return a.line < b.line})
	for key in new_order {
		now := new_lines[key][:]
		old_key := Line_Key{key.file, 0}
		if p, ok := pairs[key.file]; ok && int(key.line) < len(p) do old_key.line = p[key.line]
		old: []Insn
		if list, ok := old_lines[old_key]; ok && old_key.line != 0 {
			old = list[:]
			used_old[old_key] = true
		}
		og, ng, removed, changed := diff_line(old, now, allocator)
		append(&glyphs, ..ng)
		append(&rows, Line_Row{
			file = strings.clone(key.file, allocator), line = key.line, old_line = old_key.line,
			code = strings.clone(source_line(curr.source, key.file, key.line), allocator),
			old = og, now = ng, old_asm = asm_texts(old, allocator), now_asm = asm_texts(now, allocator),
			delta = len(now) - len(old), changed = changed || removed > 0,
		})
	}
	// Previous lines whose code is gone.
	for key in old_order {
		if used_old[key] do continue
		old := old_lines[key][:]
		og, _, _, _ := diff_line(old, nil, allocator)
		append(&rows, Line_Row{
			file = strings.clone(key.file, allocator), old_line = key.line,
			code = strings.clone(source_line(prev.source, key.file, key.line), allocator),
			old = og, old_asm = asm_texts(old, allocator), delta = -len(old), changed = true,
		})
	}
	// Cold code (check-failure paths) as one row.
	if len(old_cold) > 0 || len(new_cold) > 0 {
		og, ng, removed, changed := diff_line(old_cold[:], new_cold[:], allocator)
		append(&glyphs, ..ng)
		append(&rows, Line_Row{
			code = "cold", old = og, now = ng, cold = true,
			old_asm = asm_texts(old_cold[:], allocator), now_asm = asm_texts(new_cold[:], allocator),
			delta = len(new_cold) - len(old_cold), changed = changed || removed > 0,
		})
	}
	pd.rows = rows[:]
	pd.glyphs = glyphs[:]
	for r in rows do if r.changed do pd.changed = true
	return pd
}

// Every project proc in either build, changed ones first by |Δ|.
diff_procs :: proc(prev, curr: ^Snapshot, allocator := context.allocator) -> []Proc_Delta {
	pairs := make(map[string][]i32, allocator = context.temp_allocator)
	for file, lines in curr.source {
		if old, ok := prev.source[file]; ok do pairs[file] = pair_lines(old, lines, context.temp_allocator)
	}
	names := make(map[string]bool, allocator = context.temp_allocator)
	for s in curr.procs do names[s] = true
	for s in prev.procs do names[s] = true

	out := make([dynamic]Proc_Delta, allocator)
	for s in names do append(&out, diff_proc(prev, curr, s, pairs, allocator))
	slice.sort_by(out[:], proc(a, b: Proc_Delta) -> bool {
		if a.changed != b.changed do return a.changed
		da, db := abs(a.new_count - a.old_count), abs(b.new_count - b.old_count)
		if da != db do return da > db
		// Unchanged: the largest proc first.
		if a.new_count != b.new_count do return a.new_count > b.new_count
		return strings.compare(a.symbol, b.symbol) < 0
	})
	return out[:]
}

// SPEC §8.3 inline boxes: a (caller, callee) pair whose inlining changed.
diff_inlining :: proc(prev, curr: ^Snapshot, allocator := context.allocator) -> []Inline_Change {
	out := make([dynamic]Inline_Change, allocator)
	was := make(map[[2]string]bool, allocator = context.temp_allocator)
	now := make(map[[2]string]bool, allocator = context.temp_allocator)
	for s, p in prev.procs do for c in p.inlined do was[{s, c}] = true
	for s, p in curr.procs do for c in p.inlined do now[{s, c}] = true
	for k in was do if k not_in now {
		append(&out, Inline_Change{caller = strings.clone(k[0], allocator), callee = strings.clone(k[1], allocator), was_inlined = true})
	}
	for k in now do if k not_in was {
		append(&out, Inline_Change{caller = strings.clone(k[0], allocator), callee = strings.clone(k[1], allocator), now_inlined = true})
	}
	return out[:]
}
