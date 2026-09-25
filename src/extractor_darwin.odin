package viz

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

STRUCT_TOOL_HINT :: "dwarfdump not found - install the Xcode Command Line Tools (`xcode-select --install`) for struct/cache-line view"

Macho_Section :: struct {
	start, end: u64,
}

Macho_Symbol :: struct {
	addr:    u64,
	section: string,
	name:    string,
}

// Parses `size -m -l -x` into "SEG,sect" -> address range. Linked images list
// sections under a `Segment X:` header; object files name both inline.
macho_sections :: proc(bin_path: string) -> map[string]Macho_Section {
	sections := make(map[string]Macho_Section, context.temp_allocator)
	out := run_cmd(fmt.tprintf("size -m -l -x %s 2>/dev/null", bin_path))

	segment := ""
	for line in strings.split_lines(out, context.temp_allocator) {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "Segment ") {
			segment = trimmed[len("Segment "):]
			if idx := strings.index_byte(segment, ':'); idx >= 0 do segment = segment[:idx]
			continue
		}
		if !strings.has_prefix(trimmed, "Section ") do continue

		rest := trimmed[len("Section "):]
		colon := strings.index(rest, ": ")
		if colon < 0 do continue
		label := rest[:colon]

		key: string
		if strings.has_prefix(label, "(") {
			key, _ = strings.remove_all(strings.trim(label, "()"), " ", context.temp_allocator)
		} else {
			key = fmt.tprintf("%s,%s", segment, label)
		}

		fields := strings.fields(rest[colon + 2:], context.temp_allocator)
		if len(fields) < 3 || fields[1] != "(addr" do continue
		size, size_ok := strconv.parse_u64(fields[0])
		addr, addr_ok := strconv.parse_u64(fields[2])
		if !size_ok || !addr_ok do continue

		sections[key] = Macho_Section{start = addr, end = addr + size}
	}
	return sections
}

classify_section :: proc(section: string) -> (kind: Node_Kind, ok: bool) {
	switch section {
	case "__TEXT,__text", "__TEXT,__stubs":
		return .Code, true
	}
	if strings.has_prefix(section, "__TEXT,") || strings.has_prefix(section, "__DATA_CONST,") {
		return .Data_RO, true
	}
	if strings.has_prefix(section, "__DATA,") {
		return .Data_RW, true
	}
	return .Code, false
}

// Mach-O keeps no symbol sizes (nm -S reports zero), so each symbol's size is
// the distance to the next symbol in its section, or to the section end.
extract_symbols :: proc(bin_path: string) -> ^Node {
	tree := symbol_tree_make()
	sections := macho_sections(bin_path)

	syms := make([dynamic]Macho_Symbol, context.temp_allocator)
	out := run_cmd(fmt.tprintf("nm -m -n --defined-only %s 2>/dev/null", bin_path))

	// Line shape: `<hex addr> (SEG,sect) [flags...] [non-]external <name>`
	for line in strings.split_lines(out, context.temp_allocator) {
		sp := strings.index_byte(line, ' ')
		if sp < 0 do continue
		addr, addr_ok := strconv.parse_u64(line[:sp], 16)
		if !addr_ok do continue

		rest := line[sp + 1:]
		if !strings.has_prefix(rest, "(") do continue
		close := strings.index_byte(rest, ')')
		if close < 0 do continue
		section := rest[1:close]

		ext := strings.index(rest, "external ")
		if ext < 0 do continue
		name := rest[ext + len("external "):]
		name = strings.trim_prefix(name, "(was a private external) ")

		// Assembler-local labels alias real symbols.
		if strings.has_prefix(name, "ltmp") || strings.has_prefix(name, "l_") do continue
		// C symbols carry a leading underscore in Mach-O.
		name = strings.trim_prefix(name, "_")

		append(&syms, Macho_Symbol{addr = addr, section = section, name = name})
	}

	slice.stable_sort_by(syms[:], proc(a, b: Macho_Symbol) -> bool {
		if a.section != b.section do return a.section < b.section
		return a.addr < b.addr
	})

	for s, i in syms {
		sect, has_sect := sections[s.section]
		if !has_sect || s.addr < sect.start do continue

		kind, kind_ok := classify_section(s.section)
		if !kind_ok do continue

		end := sect.end
		if i + 1 < len(syms) && syms[i + 1].section == s.section {
			end = min(end, syms[i + 1].addr)
		}
		if end <= s.addr do continue

		symbol_tree_add(&tree, s.name, end - s.addr, kind)
	}

	return tree.root
}

Dwarf_Die :: struct {
	offset:     u64,
	tag:        string,
	depth:      int,
	parent:     int, // index into the DIE list, -1 at top level
	name:       string,
	type_ref:   u64,
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
				name   = strings.clone(m.name if m.name != "" else "<anon>"),
				offset = u32(m.member_loc),
				size   = u32(dwarf_type_size(dies[:], by_offset, m.type_ref)),
			})
		}

		finalize_struct(n)
		append(&root.children, n)
		root.size += n.size
	}

	return root, true
}
