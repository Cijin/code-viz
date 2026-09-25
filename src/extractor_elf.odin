#+build !darwin
package viz

import "core:fmt"
import "core:strconv"
import "core:strings"

STRUCT_TOOL_HINT :: "pahole not found - install the `dwarves` package for struct/cache-line view"

classify_symbol_kind :: proc(type_char: u8) -> (kind: Node_Kind, ok: bool) {
	switch type_char {
	case 'T', 't', 'W', 'w':
		return .Code, true
	case 'D', 'd', 'B', 'b', 'V', 'v':
		return .Data_RW, true
	case 'R', 'r':
		return .Data_RO, true
	}
	return .Code, false
}

// Parses `nm -S --size-sort --radix=d` output into a Root -> Package -> Symbol tree.
// ELF records symbol sizes, so nm reports them directly.
extract_symbols :: proc(bin_path: string) -> ^Node {
	tree := symbol_tree_make()

	cmd := fmt.tprintf("nm -S --size-sort --radix=d %s 2>/dev/null", bin_path)
	out := run_cmd(cmd)
	lines := strings.split_lines(out, context.temp_allocator)

	for line in lines {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 4 do continue

		size_v, size_ok := strconv.parse_u64(fields[1], 10)
		if !size_ok || size_v == 0 do continue

		kind, kind_ok := classify_symbol_kind(fields[2][0])
		if !kind_ok do continue

		symbol_tree_add(&tree, fields[3], size_v, kind)
	}

	return tree.root
}

parse_struct_summary :: proc(line: string, n: ^Node) {
	if idx := strings.index(line, "size:"); idx >= 0 {
		rest := strings.trim_space(line[idx + len("size:"):])
		numstr := rest
		if end := strings.index_any(rest, ", "); end >= 0 {
			numstr = rest[:end]
		}
		if v, ok := strconv.parse_u64(numstr, 10); ok {
			n.size = v
		}
	}
	if idx := strings.index(line, "cachelines:"); idx >= 0 {
		rest := strings.trim_space(line[idx + len("cachelines:"):])
		numstr := rest
		if end := strings.index_any(rest, ", "); end >= 0 {
			numstr = rest[:end]
		}
		if v, ok := strconv.parse_u64(numstr, 10); ok {
			n.cachelines = u32(v)
		}
	}
}

// Matches trailing pahole member comments of the form `/*   offset   size */`
// (offset may be `bitoff:bitfield`) and records the field's name/offset/size.
try_parse_field :: proc(line: string, n: ^Node) {
	c_start := strings.index(line, "/*")
	if c_start < 0 do return
	c_end := strings.index(line, "*/")
	if c_end < 0 || c_end <= c_start do return

	comment := strings.trim_space(line[c_start + 2:c_end])
	before := strings.trim_space(line[:c_start])
	if before == "" do return

	toks := strings.fields(comment, context.temp_allocator)
	if len(toks) != 2 do return

	off_tok := toks[0]
	if idx := strings.index_byte(off_tok, ':'); idx >= 0 {
		off_tok = off_tok[:idx]
	}
	offset_v, off_ok := strconv.parse_u64(off_tok, 10)
	size_v, size_ok := strconv.parse_u64(toks[1], 10)
	if !off_ok || !size_ok do return

	name := strings.trim_space(strings.trim_suffix(before, ";"))
	if idx := strings.last_index_any(name, " \t*}"); idx >= 0 {
		name = name[idx + 1:]
	}
	if idx := strings.index_byte(name, '['); idx >= 0 {
		name = name[:idx]
	}
	name = strings.trim_space(name)
	if name == "" do return

	append(&n.fields, Struct_Field{
		name       = strings.clone(name),
		offset     = u32(offset_v),
		size       = u32(size_v),
		is_padding = false,
	})
}

// Parses `pahole` output into a Root -> Struct tree with field/padding detail.
// Returns ok=false when pahole is not installed on the system.
extract_structs :: proc(bin_path: string) -> (root: ^Node, ok: bool) {
	root = new_struct_root()

	which := strings.trim_space(run_cmd("command -v pahole 2>/dev/null"))
	if which == "" {
		return root, false
	}

	out := run_cmd(fmt.tprintf("pahole %s 2>/dev/null", bin_path))
	lines := strings.split_lines(out, context.temp_allocator)

	cur: ^Node
	depth := 0

	for line in lines {
		trimmed := strings.trim_space(line)

		if cur == nil {
			if strings.has_prefix(trimmed, "struct ") && strings.has_suffix(trimmed, "{") {
				rest := trimmed[len("struct "):]
				name := rest
				if idx := strings.index_any(rest, " \t{"); idx >= 0 {
					name = rest[:idx]
				}
				name = strings.trim_space(name)
				if name != "" {
					cur = new(Node)
					cur.kind = .Struct
					cur.name = strings.clone(name)
					depth = 1
				}
			}
			continue
		}

		open_count := strings.count(line, "{")
		close_count := strings.count(line, "}")
		new_depth := depth + open_count - close_count

		if strings.has_prefix(trimmed, "/* size:") {
			parse_struct_summary(trimmed, cur)
		} else if !strings.has_prefix(trimmed, "/*") {
			try_parse_field(line, cur)
		}

		if new_depth <= 0 {
			finalize_struct(cur)
			append(&root.children, cur)
			cur = nil
			depth = 0
		} else {
			depth = new_depth
		}
	}

	for s in root.children {
		root.size += s.size
	}

	return root, true
}
