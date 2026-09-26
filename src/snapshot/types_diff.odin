package snapshot

import "core:slice"
import "core:strings"

// SPEC §7.3: match types by name and fields by name; report size and
// padding deltas, a reorder that saves bytes, and cache-line placement.

CACHE_LINE :: 64
PLACEMENT_ELEMS :: 8
ARRAY_ELEMS :: 10_000

Byte_Range :: struct {
	first, last: int, // inclusive
}

Placement :: struct {
	lines:    int,   // cache lines used by the first PLACEMENT_ELEMS elements
	spanning: []int, // elements touching more lines than their size needs
}

Type_Delta :: struct {
	name:       string,
	old:        Maybe(Type_Layout), // nil for a new type
	new:        Maybe(Type_Layout), // nil for a removed type
	size_delta: int,
	pad_delta:  int,
	suggested:  Maybe(Type_Layout), // only when it saves bytes vs `new`
	moved:      []string,           // fields the suggestion moves
	new_fields: []string,           // fields added by this build
}

padding_bytes :: proc(t: Type_Layout) -> int {
	used := 0
	for f in t.fields do used += f.size
	return t.size - used
}

// Gaps between fields and the tail gap up to `size`.
padding_ranges :: proc(t: Type_Layout, allocator := context.allocator) -> []Byte_Range {
	out := make([dynamic]Byte_Range, allocator)
	cursor := 0
	for f in t.fields {
		if f.offset > cursor do append(&out, Byte_Range{cursor, f.offset - 1})
		cursor = max(cursor, f.offset + f.size)
	}
	if t.size > cursor do append(&out, Byte_Range{cursor, t.size - 1})
	return out[:]
}

align_up :: proc(v, a: int) -> int {
	if a <= 1 do return v
	return (v + a - 1) / a * a
}

// Lays out `fields` in the given order with natural alignment.
@(private = "file")
layout_in_order :: proc(t: Type_Layout, order: []Field, allocator := context.allocator) -> Type_Layout {
	out := t
	fields := make([]Field, len(order), allocator)
	cursor := 0
	for f, i in order {
		fields[i] = f
		fields[i].offset = align_up(cursor, f.align)
		cursor = fields[i].offset + f.size
	}
	out.fields = fields
	out.size = align_up(cursor, t.align)
	return out
}

// Keeps the declared order but moves later, smaller fields into the holes
// that alignment leaves before a field. This is the smallest edit, and it is
// the fix `fixtures/expected.md` and Memory.dc.html show.
@(private = "file")
fill_holes :: proc(t: Type_Layout, allocator := context.allocator) -> []Field {
	placed := make([]bool, len(t.fields), context.temp_allocator)
	order := make([dynamic]Field, allocator)
	cursor := 0
	for f, i in t.fields {
		if placed[i] do continue
		target := align_up(cursor, f.align)
		for j := i + 1; j < len(t.fields) && cursor < target; j += 1 {
			g := t.fields[j]
			if placed[j] do continue
			at := align_up(cursor, g.align)
			if at + g.size <= target {
				placed[j] = true
				append(&order, g)
				cursor = at + g.size
			}
		}
		placed[i] = true
		append(&order, f)
		cursor = align_up(cursor, f.align) + f.size
	}
	return order[:]
}

// SPEC §7.3's rule: sort by alignment (descending), declared order on ties.
@(private = "file")
sort_by_align :: proc(t: Type_Layout, allocator := context.allocator) -> []Field {
	order := slice.clone(t.fields, allocator)
	slice.stable_sort_by(order, proc(a, b: Field) -> bool {return a.align > b.align})
	return order
}

// A reorder that saves bytes, if there is one. Hole filling wins ties
// because it changes fewer lines of source.
suggest_reorder :: proc(t: Type_Layout, allocator := context.allocator) -> (Type_Layout, bool) {
	filled := layout_in_order(t, fill_holes(t, context.temp_allocator), allocator)
	sorted := layout_in_order(t, sort_by_align(t, context.temp_allocator), allocator)
	best := filled
	if sorted.size < filled.size do best = sorted
	if best.size >= t.size do return {}, false
	return best, true
}

// Placement of the first PLACEMENT_ELEMS elements of an array of `size`.
placement :: proc(size: int, allocator := context.allocator) -> Placement {
	if size <= 0 do return {}
	spanning := make([dynamic]int, allocator)
	for i in 0 ..< PLACEMENT_ELEMS {
		start, end := i * size, (i + 1) * size - 1
		// An element larger than a line always spans lines; it is split only
		// when misalignment makes it touch one more than its size needs.
		touched := end / CACHE_LINE - start / CACHE_LINE + 1
		if touched > (size + CACHE_LINE - 1) / CACHE_LINE do append(&spanning, i)
	}
	total := PLACEMENT_ELEMS * size
	return Placement{lines = (total + CACHE_LINE - 1) / CACHE_LINE, spanning = spanning[:]}
}

// Bytes and cache lines for ARRAY_ELEMS elements.
array_totals :: proc(size: int) -> (bytes, lines: int) {
	bytes = ARRAY_ELEMS * size
	return bytes, (bytes + CACHE_LINE - 1) / CACHE_LINE
}

@(private = "file")
has_field :: proc(t: Type_Layout, name: string) -> bool {
	for f in t.fields do if f.name == name do return true
	return false
}

diff_types :: proc(prev, curr: map[string]Type_Layout, allocator := context.allocator) -> []Type_Delta {
	out := make([dynamic]Type_Delta, allocator)
	for name, t in curr {
		d := Type_Delta{name = name, new = t}
		if old, ok := prev[name]; ok {
			d.old = old
			d.size_delta = t.size - old.size
			d.pad_delta = padding_bytes(t) - padding_bytes(old)
			added := make([dynamic]string, allocator)
			for f in t.fields do if !has_field(old, f.name) do append(&added, f.name)
			d.new_fields = added[:]
		}
		if fix, ok := suggest_reorder(t, allocator); ok {
			d.suggested = fix
			moved := make([dynamic]string, allocator)
			for f, i in fix.fields do if i >= len(t.fields) || t.fields[i].name != f.name do append(&moved, f.name)
			d.moved = moved[:]
		}
		append(&out, d)
	}
	for name, t in prev do if name not_in curr {
		append(&out, Type_Delta{name = name, old = t, size_delta = -t.size, pad_delta = -padding_bytes(t)})
	}
	// Largest change first; stable by name so the order doesn't flicker.
	slice.sort_by(out[:], proc(a, b: Type_Delta) -> bool {
		if abs(a.size_delta) != abs(b.size_delta) do return abs(a.size_delta) > abs(b.size_delta)
		return strings.compare(a.name, b.name) < 0
	})
	return out[:]
}

// Byte cells for the glance strip: data, padding, or data of a new field.
byte_cells :: proc(t: Type_Layout, new_fields: []string, allocator := context.allocator) -> []Byte_Cell {
	cells := make([]Byte_Cell, t.size, allocator)
	for &c in cells do c = .Padding
	for f in t.fields {
		kind := slice.contains(new_fields, f.name) ? Byte_Cell.New_Data : Byte_Cell.Data
		for b in f.offset ..< min(f.offset + f.size, t.size) do cells[b] = kind
	}
	return cells
}

// "frame::Frame_Header" -> "Frame_Header".
short_name :: proc(name: string) -> string {
	if i := strings.last_index(name, "::"); i >= 0 do return name[i + 2:]
	return name
}
