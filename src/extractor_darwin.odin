package viz

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

STRUCT_TOOL_HINT :: "dwarfdump not found - install the Xcode Command Line Tools (`xcode-select --install`) for struct/cache-line view"

Dwarf_Die :: struct {
	offset:     u64,
	tag:        string,
	depth:      int,
	parent:     int, // index into the DIE list, -1 at top level
	name:       string,
	type_ref:   u64,
	type_name:  string, // quoted name dwarfdump prints beside the type ref
	byte_size:  u64,
	has_size:   bool,
	member_loc: u64,
	count:      u64, // subrange element count
	has_count:  bool,
	declaration: bool,
}

// First hex/decimal number inside an attribute value like `(0x1cf6a "t::Foo")`
// or `(DW_OP_plus_uconst 0x28)`.
dwarf_value_number :: proc(value: string) -> (v: u64, ok: bool) {
	for raw in strings.fields(value, context.temp_allocator) {
		tok := strings.trim(raw, "()")
		if n, n_ok := strconv.parse_u64(tok); n_ok do return n, true
	}
	return 0, false
}

// Reads `dwarfdump --debug-info` text into a flat DIE list with parent links.
parse_dwarfdump :: proc(out: string) -> [dynamic]Dwarf_Die {
	dies := make([dynamic]Dwarf_Die, context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)

	for line in strings.split_lines(out, context.temp_allocator) {
		// DIE header: `0x0001cf6a:   DW_TAG_structure_type`; NULL closes a level.
		if strings.has_prefix(line, "0x") {
			colon := strings.index_byte(line, ':')
			if colon < 0 do continue
			offset, off_ok := strconv.parse_u64(line[:colon])
			if !off_ok do continue

			body := line[colon + 1:]
			tag := strings.trim_space(body)
			depth := len(body) - len(strings.trim_left_space(body))

			for len(stack) > 0 && dies[stack[len(stack) - 1]].depth >= depth {
				pop(&stack)
			}
			if tag == "NULL" do continue

			parent := len(stack) > 0 ? stack[len(stack) - 1] : -1
			append(&dies, Dwarf_Die{offset = offset, tag = tag, depth = depth, parent = parent})
			append(&stack, len(dies) - 1)
			continue
		}

		if len(dies) == 0 do continue
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, "DW_AT_") do continue

		attr := trimmed
		value := ""
		if idx := strings.index_any(trimmed, " \t"); idx >= 0 {
			attr = trimmed[:idx]
			value = strings.trim_space(trimmed[idx:])
		}

		d := &dies[len(dies) - 1]
		switch attr {
		case "DW_AT_name":
			d.name = strings.trim(value, "()\"")
		case "DW_AT_type":
			d.type_ref, _ = dwarf_value_number(value)
			if q0 := strings.index_byte(value, '"'); q0 >= 0 {
				if q1 := strings.last_index_byte(value, '"'); q1 > q0 do d.type_name = value[q0 + 1:q1]
			}
		case "DW_AT_byte_size":
			d.byte_size, d.has_size = dwarf_value_number(value)
		case "DW_AT_data_member_location":
			d.member_loc, _ = dwarf_value_number(value)
		case "DW_AT_data_bit_offset":
			if bits, ok := dwarf_value_number(value); ok do d.member_loc = bits / 8
		case "DW_AT_count":
			d.count, d.has_count = dwarf_value_number(value)
		case "DW_AT_upper_bound":
			if ub, ok := dwarf_value_number(value); ok {
				d.count, d.has_count = ub + 1, true
			}
		case "DW_AT_declaration":
			d.declaration = true
		}
	}
	return dies
}

// Resolves a type's byte size through typedefs/qualifiers and array extents.
dwarf_type_size :: proc(dies: []Dwarf_Die, by_offset: map[u64]int, ref: u64, depth := 0) -> u64 {
	idx, found := by_offset[ref]
	if !found || depth > 32 do return 0
	d := dies[idx]
	if d.has_size do return d.byte_size

	switch d.tag {
	case "DW_TAG_pointer_type", "DW_TAG_reference_type", "DW_TAG_subroutine_type":
		return size_of(rawptr)
	case "DW_TAG_array_type":
		n: u64 = 1
		for j := idx + 1; j < len(dies) && dies[j].depth > d.depth; j += 1 {
			if dies[j].parent == idx && dies[j].tag == "DW_TAG_subrange_type" && dies[j].has_count {
				n *= dies[j].count
			}
		}
		return n * dwarf_type_size(dies, by_offset, d.type_ref, depth + 1)
	}
	return dwarf_type_size(dies, by_offset, d.type_ref, depth + 1)
}

// Rewrites dwarfdump's C-style type names in Odin syntax: `T *` -> `^T`,
// `T[3]` -> `[3]T`.
odin_type_spelling :: proc(c_name: string) -> string {
	name := strings.trim_space(c_name)
	prefix := strings.builder_make(context.temp_allocator)
	for {
		if strings.has_suffix(name, "*") {
			strings.write_byte(&prefix, '^')
			name = strings.trim_space(name[:len(name) - 1])
		} else if strings.has_suffix(name, "]") {
			// A run of extents keeps its order: C `T[3][2]` is Odin `[3][2]T`.
			run_start := len(name)
			for strings.has_suffix(name[:run_start], "]") {
				open := strings.last_index_byte(name[:run_start], '[')
				if open < 0 do break
				run_start = open
			}
			if run_start == len(name) do break
			strings.write_string(&prefix, name[run_start:])
			name = strings.trim_space(name[:run_start])
		} else {
			break
		}
	}
	return fmt.aprintf("%s%s", strings.to_string(prefix), name)
}

// Builds the struct tree from DWARF via Apple's dwarfdump. Linked binaries keep
// their DWARF in the `.dSYM` bundle that `odin build -debug` writes alongside.
extract_structs :: proc(bin_path: string) -> (root: ^Node, ok: bool) {
	root = new_struct_root()

	which := strings.trim_space(run_cmd("command -v dwarfdump 2>/dev/null"))
	if which == "" {
		return root, false
	}

	dwarf_path := bin_path
	if dsym := fmt.tprintf("%s.dSYM", bin_path); os.exists(dsym) {
		dwarf_path = dsym
	}

	out := run_cmd(fmt.tprintf("dwarfdump --debug-info %s 2>/dev/null", dwarf_path))
	dies := parse_dwarfdump(out)

	by_offset := make(map[u64]int, context.temp_allocator)
	for d, i in dies do by_offset[d.offset] = i

	seen := make(map[string]bool, context.temp_allocator)

	for d, i in dies {
		if d.tag != "DW_TAG_structure_type" || d.name == "" || d.declaration || !d.has_size do continue
		if d.name in seen do continue
		seen[d.name] = true

		n := new(Node)
		n.kind = .Struct
		n.name = strings.clone(d.name)
		n.size = d.byte_size

		for j := i + 1; j < len(dies) && dies[j].depth > d.depth; j += 1 {
			m := dies[j]
			if m.parent != i || m.tag != "DW_TAG_member" do continue
			append(&n.fields, Struct_Field{
				name      = strings.clone(m.name if m.name != "" else "<anon>"),
				type_name = odin_type_spelling(m.type_name),
				offset    = u32(m.member_loc),
				size      = u32(dwarf_type_size(dies[:], by_offset, m.type_ref)),
			})
		}

		finalize_struct(n)
		append(&root.children, n)
		root.size += n.size
	}

	return root, true
}
