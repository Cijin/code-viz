package analyze

import "core:slice"
import "core:strconv"
import "core:strings"
import snap "../snapshot"

// SPEC §6.1 (type layout) and §6.3 (inlining) from one pass over
// `llvm-dwarfdump --debug-info` text.

Die_Tag :: enum u8 {
	Other,
	Compile_Unit,
	Structure,
	Union,
	Member,
	Base,
	Typedef,
	Pointer,
	Array,
	Subrange,
	Enumeration,
	Const,
	Volatile,
	Subprogram,
	Inlined,
	Subroutine_Type,
}

Die :: struct {
	offset:      u64,
	tag:         Die_Tag,
	depth:       int,
	parent:      int, // index, -1 at top level
	name:        string,
	type_ref:    u64,
	type_name:   string, // the quoted name beside a DW_AT_type ref
	byte_size:   int,
	has_size:    bool,
	alignment:   int,
	member_loc:  int,
	count:       int,
	has_count:   bool,
	decl_file:   string,
	decl_line:   i32,
	origin_name: string, // DW_AT_abstract_origin of an inlined subroutine
	declaration: bool,
}

@(private = "file")
tag_of :: proc(s: string) -> Die_Tag {
	switch s {
	case "DW_TAG_compile_unit":       return .Compile_Unit
	case "DW_TAG_structure_type":     return .Structure
	case "DW_TAG_union_type":         return .Union
	case "DW_TAG_member":             return .Member
	case "DW_TAG_base_type":          return .Base
	case "DW_TAG_typedef":            return .Typedef
	case "DW_TAG_pointer_type":       return .Pointer
	case "DW_TAG_array_type":         return .Array
	case "DW_TAG_subrange_type":      return .Subrange
	case "DW_TAG_enumeration_type":   return .Enumeration
	case "DW_TAG_const_type":         return .Const
	case "DW_TAG_volatile_type":      return .Volatile
	case "DW_TAG_subprogram":         return .Subprogram
	case "DW_TAG_inlined_subroutine": return .Inlined
	case "DW_TAG_subroutine_type":    return .Subroutine_Type
	}
	return .Other
}

// First number in an attribute value: `(0x18)`, `(8)`,
// `(DW_OP_plus_uconst 0x10)`, `(0x0000d312 "u8")`.
@(private = "file")
first_number :: proc(value: string) -> (v: u64, ok: bool) {
	for tok in strings.fields(value, context.temp_allocator) {
		t := strings.trim(tok, "()")
		if n, nok := strconv.parse_u64(t); nok do return n, true
	}
	return 0, false
}

@(private = "file")
quoted :: proc(value: string) -> string {
	a := strings.index_byte(value, '"')
	b := strings.last_index_byte(value, '"')
	if a < 0 || b <= a do return ""
	return value[a + 1:b]
}

// Parses dwarfdump text into a flat DIE list with parent links. Strings in
// the result point into `text`.
parse_dies :: proc(text: string, allocator := context.allocator) -> []Die {
	dies := make([dynamic]Die, allocator)
	stack := make([dynamic]int, context.temp_allocator)

	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "0x") {
			colon := strings.index_byte(line, ':')
			if colon < 0 do continue
			off, ok := strconv.parse_u64(line[:colon])
			if !ok do continue
			body := line[colon + 1:]
			tag := strings.trim_space(body)
			depth := len(body) - len(strings.trim_left_space(body))
			for len(stack) > 0 && dies[stack[len(stack) - 1]].depth >= depth do pop(&stack)
			if tag == "NULL" do continue
			parent := len(stack) > 0 ? stack[len(stack) - 1] : -1
			append(&dies, Die{offset = off, tag = tag_of(tag), depth = depth, parent = parent})
			append(&stack, len(dies) - 1)
			continue
		}
		if len(dies) == 0 do continue
		t := strings.trim_left_space(line)
		if !strings.has_prefix(t, "DW_AT_") do continue
		sep := strings.index_any(t, " \t")
		if sep < 0 do continue
		attr, value := t[:sep], strings.trim_space(t[sep:])
		d := &dies[len(dies) - 1]
		switch attr {
		case "DW_AT_name":
			d.name = quoted(value)
		case "DW_AT_type":
			d.type_ref, _ = first_number(value)
			d.type_name = quoted(value)
		case "DW_AT_byte_size":
			v, ok := first_number(value)
			d.byte_size, d.has_size = int(v), ok
		case "DW_AT_alignment":
			v, _ := first_number(value)
			d.alignment = int(v)
		case "DW_AT_data_member_location":
			v, _ := first_number(value)
			d.member_loc = int(v)
		case "DW_AT_count":
			v, ok := first_number(value)
			d.count, d.has_count = int(v), ok
		case "DW_AT_upper_bound":
			if v, ok := first_number(value); ok do d.count, d.has_count = int(v) + 1, true
		case "DW_AT_decl_file":
			d.decl_file = quoted(value)
		case "DW_AT_decl_line":
			v, _ := first_number(value)
			d.decl_line = i32(v)
		case "DW_AT_abstract_origin":
			d.origin_name = quoted(value)
		case "DW_AT_declaration":
			d.declaration = true
		}
	}
	return dies[:]
}

Die_Index :: map[u64]int

index_dies :: proc(dies: []Die, allocator := context.allocator) -> Die_Index {
	idx := make(Die_Index, len(dies), allocator)
	for d, i in dies do idx[d.offset] = i
	return idx
}

// Byte size of a type, following typedefs/qualifiers and array extents.
type_size :: proc(dies: []Die, idx: Die_Index, ref: u64, depth := 0) -> int {
	i, ok := idx[ref]
	if !ok || depth > 32 do return 0
	d := dies[i]
	if d.has_size do return d.byte_size
	#partial switch d.tag {
	case .Pointer, .Subroutine_Type:
		return size_of(rawptr)
	case .Array:
		n := 1
		for j := i + 1; j < len(dies) && dies[j].depth > d.depth; j += 1 {
			if dies[j].parent == i && dies[j].tag == .Subrange && dies[j].has_count do n *= dies[j].count
		}
		return n * type_size(dies, idx, d.type_ref, depth + 1)
	}
	return type_size(dies, idx, d.type_ref, depth + 1)
}

// Alignment of a type when the member has no DW_AT_alignment.
type_align :: proc(dies: []Die, idx: Die_Index, ref: u64, depth := 0) -> int {
	i, ok := idx[ref]
	if !ok || depth > 32 do return 1
	d := dies[i]
	if d.alignment > 0 do return d.alignment
	#partial switch d.tag {
	case .Base, .Enumeration:
		return max(d.byte_size, 1)
	case .Pointer, .Subroutine_Type:
		return size_of(rawptr)
	case .Typedef, .Const, .Volatile, .Array:
		return type_align(dies, idx, d.type_ref, depth + 1)
	}
	return max(d.byte_size, 1)
}

// Project-relative path, or "" when `path` is outside the project.
project_relative :: proc(path, root: string) -> string {
	r := strings.trim_right(root, "/")
	if !strings.has_prefix(path, r) || len(path) <= len(r) || path[len(r)] != '/' do return ""
	return path[len(r) + 1:]
}

// SPEC §6.1: named structs declared under `root`, with fields sorted by
// offset. Types repeat per compile unit; the first definition wins.
extract_types :: proc(dies: []Die, idx: Die_Index, root: string, allocator := context.allocator) -> map[string]snap.Type_Layout {
	out := make(map[string]snap.Type_Layout, allocator = allocator)
	for d, i in dies {
		if d.tag != .Structure || d.name == "" || d.declaration || !d.has_size do continue
		rel := project_relative(d.decl_file, root)
		if rel == "" || d.name in out do continue

		fields := make([dynamic]snap.Field, allocator)
		for j := i + 1; j < len(dies) && dies[j].depth > d.depth; j += 1 {
			m := dies[j]
			if m.parent != i || m.tag != .Member do continue
			align := m.alignment > 0 ? m.alignment : type_align(dies, idx, m.type_ref)
			append(&fields, snap.Field{
				name      = strings.clone(m.name, allocator),
				type_name = strings.clone(m.type_name, allocator),
				offset    = m.member_loc,
				size      = type_size(dies, idx, m.type_ref),
				align     = align,
			})
		}
		slice.stable_sort_by(fields[:], proc(a, b: snap.Field) -> bool {return a.offset < b.offset})

		align := d.alignment
		if align == 0 do for f in fields do align = max(align, f.align)
		out[strings.clone(d.name, allocator)] = snap.Type_Layout{
			name   = strings.clone(d.name, allocator),
			pos    = {file = strings.clone(rel, allocator), line = d.decl_line},
			size   = d.byte_size,
			align  = max(align, 1),
			fields = fields[:],
		}
	}
	return out
}

// SPEC §6.3: caller -> callees inlined into it. The caller is the enclosing
// DW_TAG_subprogram; nested inlining still credits the outer subprogram.
extract_inlining :: proc(dies: []Die, allocator := context.allocator) -> map[string][]string {
	tmp := make(map[string][dynamic]string, allocator = context.temp_allocator)
	for d in dies {
		if d.tag != .Inlined || d.origin_name == "" do continue
		p := d.parent
		for p >= 0 && dies[p].tag != .Subprogram do p = dies[p].parent
		if p < 0 || dies[p].name == "" do continue
		caller := dies[p].name
		list := tmp[caller]
		if list.allocator.procedure == nil do list.allocator = context.temp_allocator
		if !slice.contains(list[:], d.origin_name) do append(&list, d.origin_name)
		tmp[caller] = list
	}
	out := make(map[string][]string, allocator = allocator)
	for caller, list in tmp {
		callees := make([]string, len(list), allocator)
		for c, k in list do callees[k] = strings.clone(c, allocator)
		out[strings.clone(caller, allocator)] = callees
	}
	return out
}

Proc_Info :: struct {
	pos:         snap.Source_Pos,
	return_type: string,
	return_size: int,
}

// Declaration and return type of each project procedure.
extract_proc_info :: proc(dies: []Die, idx: Die_Index, root: string, allocator := context.allocator) -> map[string]Proc_Info {
	out := make(map[string]Proc_Info, allocator = allocator)
	for d in dies {
		if d.tag != .Subprogram || d.name == "" || d.declaration do continue
		rel := project_relative(d.decl_file, root)
		if rel == "" || d.name in out do continue
		out[strings.clone(d.name, allocator)] = Proc_Info{
			pos         = {file = strings.clone(rel, allocator), line = d.decl_line},
			return_type = strings.clone(d.type_name, allocator),
			return_size = d.type_ref != 0 ? type_size(dies, idx, d.type_ref) : 0,
		}
	}
	return out
}

Dwarf_Result :: struct {
	types:    map[string]snap.Type_Layout,
	inlining: map[string][]string,
	procs:    map[string]Proc_Info,
}

// Runs llvm-dwarfdump on the build's DWARF and extracts types, inlining and
// procedure info in one pass.
analyze_dwarf :: proc(artifact, root: string, allocator := context.allocator) -> (res: Dwarf_Result, ok: bool) {
	tool := find_tool("llvm-dwarfdump")
	if tool == "" do return
	path := dwarf_path(artifact, context.temp_allocator)
	text := run_tool({tool, "--debug-info", path}, context.temp_allocator) or_return
	dies := parse_dies(text, context.temp_allocator)
	idx := index_dies(dies, context.temp_allocator)
	res.types = extract_types(dies, idx, root, allocator)
	res.inlining = extract_inlining(dies, allocator)
	res.procs = extract_proc_info(dies, idx, root, allocator)
	return res, true
}
