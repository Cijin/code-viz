package snapshot

import "core:slice"
import "core:strings"

// A Delta compares two green snapshots. It is self-contained: everything it
// references is copied into the allocator it was built with, so the UI can
// keep it after the pipeline drops the snapshots.

Delta :: struct {
	from, to: Build_Id, // equal on the first build
	types:    []Type_Delta,
	procs:    []Proc_Delta, // changed first
	inline:   []Inline_Change,
	safety:   Safety_Delta,
	blocks:   Blocks,
}

clone_layout :: proc(t: Type_Layout, allocator := context.allocator) -> Type_Layout {
	out := t
	out.name = strings.clone(t.name, allocator)
	out.pos.file = strings.clone(t.pos.file, allocator)
	out.fields = slice.clone(t.fields, allocator)
	for &f in out.fields {
		f.name = strings.clone(f.name, allocator)
		f.type_name = strings.clone(f.type_name, allocator)
	}
	return out
}

@(private = "file")
clone_strings :: proc(ss: []string, allocator := context.allocator) -> []string {
	out := make([]string, len(ss), allocator)
	for s, i in ss do out[i] = strings.clone(s, allocator)
	return out
}

@(private = "file")
clone_maybe :: proc(m: Maybe(Type_Layout), allocator := context.allocator) -> Maybe(Type_Layout) {
	if t, ok := m.?; ok do return clone_layout(t, allocator)
	return nil
}

// `prev` may be nil (first build). Result is allocated with `allocator`.
diff :: proc(prev, curr: ^Snapshot, allocator := context.allocator) -> Delta {
	// With no previous build, compare the build with itself: nothing is
	// marked changed, but the lenses still get the current state.
	prev := prev
	if prev == nil do prev = curr
	d := Delta{from = prev.id, to = curr.id}

	raw := diff_types(prev.types, curr.types, context.temp_allocator)
	types := make([dynamic]Type_Delta, allocator)
	for td in raw {
		append(&types, Type_Delta{
			name       = strings.clone(td.name, allocator),
			old        = clone_maybe(td.old, allocator),
			new        = clone_maybe(td.new, allocator),
			size_delta = td.size_delta,
			pad_delta  = td.pad_delta,
			suggested  = clone_maybe(td.suggested, allocator),
			moved      = clone_strings(td.moved, allocator),
			new_fields = clone_strings(td.new_fields, allocator),
		})
	}
	// Changed types first; then the ones a reorder would shrink most, then
	// the most padding, so an unchanged build still opens on a useful type.
	slice.sort_by(types[:], proc(a, b: Type_Delta) -> bool {
		ca, cb := type_changed(a), type_changed(b)
		if ca != cb do return ca
		if abs(a.size_delta) != abs(b.size_delta) do return abs(a.size_delta) > abs(b.size_delta)
		sa, sb := reorder_savings(a), reorder_savings(b)
		if sa != sb do return sa > sb
		pa, pb := type_padding(a), type_padding(b)
		if pa != pb do return pa > pb
		return strings.compare(a.name, b.name) < 0
	})
	d.types = types[:]
	d.procs = diff_procs(prev, curr, allocator)
	d.inline = diff_inlining(prev, curr, allocator)
	d.safety = diff_safety(prev, curr, allocator)
	d.blocks = build_blocks(prev, curr, &d, allocator)
	return d
}

type_changed :: proc(td: Type_Delta) -> bool {
	_, had := td.old.?
	return td.size_delta != 0 || td.pad_delta != 0 || len(td.new_fields) > 0 || !had
}

@(private = "file")
reorder_savings :: proc(td: Type_Delta) -> int {
	t, ok := td.new.?
	fix, fok := td.suggested.?
	return ok && fok ? t.size - fix.size : 0
}

@(private = "file")
type_padding :: proc(td: Type_Delta) -> int {
	t, ok := td.new.?
	return ok ? padding_bytes(t) : 0
}

// Glance dot for one lane: cost if it got worse, gain if better.
dot_for :: proc(v: int) -> Dot {
	return v > 0 ? .Cost : (v < 0 ? .Gain : .Neutral)
}

// Builds the glance view model. `history` holds the build dots of the last
// green builds (oldest first); see record_build.
build_glance :: proc(d: ^Delta, history: []Build_Dots, allocator := context.allocator) -> Glance {
	g := Glance{status = .Ok, from = d.from, to = d.to}

	if len(d.types) > 0 && d.from != d.to {
		td := d.types[0]
		g.memory.changed = td.size_delta != 0 || td.pad_delta != 0
		g.memory.symbol = short_name(td.name)
		g.memory.delta = td.size_delta
		g.memory.old_build, g.memory.new_build = d.from, d.to
		if old, ok := td.old.?; ok do g.memory.old_cells = byte_cells(old, nil, allocator)
		if new, ok := td.new.?; ok do g.memory.new_cells = byte_cells(new, td.new_fields, allocator)
	}

	if len(d.procs) > 0 && d.procs[0].changed {
		pd := d.procs[0]
		g.exec.changed = true
		g.exec.symbol = short_name(pd.symbol)
		g.exec.delta = pd.new_count - pd.old_count
		g.exec.glyphs = pd.glyphs
		for ic in d.inline {
			if ic.caller == pd.symbol || ic.callee == pd.symbol {
				g.exec.inline = Inline_Change{
					caller      = short_name(ic.caller),
					callee      = short_name(ic.callee),
					was_inlined = ic.was_inlined,
					now_inlined = ic.now_inlined,
				}
				break
			}
		}
	}

	if len(d.safety.procs) > 0 && d.safety.procs[0].changed {
		ps := d.safety.procs[0]
		g.safety.changed = true
		g.safety.symbol = short_name(ps.symbol)
		g.safety.delta = ps.new_active - ps.old_active
		rings := make([dynamic]Glyph_Item, allocator)
		for l in ps.lines do for r in l.checks do if r.glyph == .Check do append(&rings, r)
		g.safety.now = rings[:]
	}

	// Quiet signals (no change) become "=" chips; changed ones carry a delta.
	quiet := make([dynamic]string, allocator)
	if d.safety.stack_delta == 0 do append(&quiet, "stack")
	else do g.loud = append_loud(g.loud, d.safety.stack_delta, "B stack", allocator)
	append(&quiet, "heap")
	if d.safety.opt_outs_new == d.safety.opt_outs_old do append(&quiet, "opt-out")
	else do g.loud = append_loud(g.loud, d.safety.opt_outs_new - d.safety.opt_outs_old, "opt-out", allocator)
	if !d.safety.vet_ready || len(d.safety.vet_new) == 0 do append(&quiet, "vet")
	else do g.loud = append_loud(g.loud, len(d.safety.vet_new), "vet", allocator)
	g.quiet = quiet[:]

	g.builds = history
	return g
}

// Appends one build's E/M/S dots to the history (last 16 kept). Call once
// per green build, after build_glance.
record_build :: proc(history: ^[dynamic]Build_Dots, g: Glance) {
	for &b in history do b.current = false
	append(history, Build_Dots{e = dot_for(g.exec.delta), m = dot_for(g.memory.delta), s = dot_for(g.safety.delta), current = true})
	for len(history) > 16 do ordered_remove(history, 0)
}

@(private = "file")
append_loud :: proc(list: []Signal_Chip, delta: int, label: string, allocator := context.allocator) -> []Signal_Chip {
	out := make([dynamic]Signal_Chip, allocator)
	append(&out, ..list)
	append(&out, Signal_Chip{delta = delta, label = label})
	return out[:]
}
