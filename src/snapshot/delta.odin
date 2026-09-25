package snapshot

import "core:slice"
import "core:strings"

// A Delta compares two green snapshots. It is self-contained: everything it
// references is copied into the allocator it was built with, so the UI can
// keep it after the pipeline drops the snapshots.

Delta :: struct {
	from, to: Build_Id, // equal on the first build
	types:    []Type_Delta,
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
	d := Delta{from = curr.id, to = curr.id}
	if prev == nil do return d
	d.from = prev.id

	raw := diff_types(prev.types, curr.types, context.temp_allocator)
	types := make([dynamic]Type_Delta, allocator)
	for td in raw {
		if td.size_delta == 0 && td.pad_delta == 0 && len(td.new_fields) == 0 {
			if _, has_old := td.old.?; has_old do continue
		}
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
	d.types = types[:]
	return d
}

// Glance dot for one lane: cost if it got worse, gain if better.
dot_for :: proc(v: int) -> Dot {
	return v > 0 ? .Cost : (v < 0 ? .Gain : .Neutral)
}

// Builds the glance view model. `history` holds the dots of earlier green
// builds (oldest first) and is appended to.
build_glance :: proc(d: ^Delta, history: ^[dynamic]Build_Dots, allocator := context.allocator) -> Glance {
	g := Glance{status = .Ok, from = d.from, to = d.to}

	if len(d.types) > 0 {
		td := d.types[0]
		g.memory.changed = td.size_delta != 0 || td.pad_delta != 0
		g.memory.symbol = short_name(td.name)
		g.memory.delta = td.size_delta
		g.memory.old_build, g.memory.new_build = d.from, d.to
		if old, ok := td.old.?; ok do g.memory.old_cells = byte_cells(old, nil, allocator)
		if new, ok := td.new.?; ok do g.memory.new_cells = byte_cells(new, td.new_fields, allocator)
	}

	quiet := make([dynamic]string, allocator)
	append(&quiet, "stack", "heap", "opt-out", "vet")
	g.quiet = quiet[:]

	if d.from != d.to {
		for &b in history do b.current = false
		append(history, Build_Dots{e = .Neutral, m = dot_for(g.memory.delta), s = .Neutral, current = true})
		for len(history) > 16 do ordered_remove(history, 0)
	}
	g.builds = history[:]
	return g
}
