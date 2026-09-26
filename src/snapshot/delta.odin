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

