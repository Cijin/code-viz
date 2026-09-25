package viz

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

run_cmd :: proc(cmd: string) -> string {
	cstr := strings.clone_to_cstring(cmd, context.temp_allocator)
	fp := posix.popen(cstr, "r")
	if fp == nil do return ""
	defer posix.pclose(fp)

	builder := strings.builder_make(context.temp_allocator)
	buf: [4096]u8
	for libc.fgets(raw_data(buf[:]), len(buf), fp) != nil {
		strings.write_string(&builder, string(cstring(raw_data(buf[:]))))
	}
	return strings.to_string(builder)
}

target_has_main :: proc(target_dir: string) -> bool {
	fh, err := os.open(target_dir)
	if err != nil do return false
	defer os.close(fh)

	entries, rerr := os.read_dir(fh, -1, context.temp_allocator)
	if rerr != nil do return false

	for e in entries {
		if e.type == .Directory || !strings.has_suffix(e.name, ".odin") do continue
		data, rd_err := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rd_err != nil do continue
		if strings.contains(string(data), "main :: proc") do return true
	}
	return false
}

// Runs `odin build` on target_dir with debug info and returns the compiled
// binary path used by the nm/pahole extraction passes.
compile_target :: proc(target_dir: string) -> (bin_path: string, ok: bool) {
	bin_path = "/tmp/viz_target"

	extra := ""
	if !target_has_main(target_dir) {
		extra = " -build-mode:obj"
	}

	cmd := fmt.tprintf("odin build %s -debug -out:%s%s 2>&1", target_dir, bin_path, extra)
	out := run_cmd(cmd)

	if os.exists(bin_path) {
		return bin_path, true
	}

	obj_path := fmt.tprintf("%s.o", bin_path)
	if os.exists(obj_path) {
		return strings.clone(obj_path), true
	}

	fmt.eprintln("odin build failed:")
	fmt.eprintln(out)
	return "", false
}

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
extract_symbols :: proc(bin_path: string) -> ^Node {
	root := new(Node)
	root.kind = .Root
	root.name = "Binary Footprint"

	pkg_map := make(map[string]^Node, context.temp_allocator)

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

		full_name := fields[3]
		pkg_name := "other"
		sym_name := full_name
		if idx := strings.index(full_name, "::"); idx >= 0 {
			pkg_name = full_name[:idx]
			sym_name = full_name[idx + 2:]
		}

		pkg_node, found := pkg_map[pkg_name]
		if !found {
			pkg_node = new(Node)
			pkg_node.kind = .Package
			pkg_node.name = strings.clone(pkg_name)
			append(&root.children, pkg_node)
			pkg_map[pkg_name] = pkg_node
		}

		sym_node := new(Node)
		sym_node.kind = kind
		sym_node.name = strings.clone(sym_name)
		sym_node.size = size_v
		append(&pkg_node.children, sym_node)
		pkg_node.size += size_v
	}

	for pkg in root.children {
		root.size += pkg.size
	}

	return root
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

// Sorts fields by offset and synthesizes PADDING fields for alignment holes
// and trailing padding, accumulating node.pad_bytes.
finalize_struct :: proc(n: ^Node) {
	fs := n.fields[:]
	for i := 1; i < len(fs); i += 1 {
		j := i
		for j > 0 && fs[j - 1].offset > fs[j].offset {
			fs[j - 1], fs[j] = fs[j], fs[j - 1]
			j -= 1
		}
	}

	merged: [dynamic]Struct_Field
	cursor: u64 = 0
	for f in fs {
		if u64(f.offset) > cursor {
			gap := u64(f.offset) - cursor
			append(&merged, Struct_Field{name = "PADDING", offset = u32(cursor), size = u32(gap), is_padding = true})
			n.pad_bytes += gap
		}
		append(&merged, f)
		end := u64(f.offset) + u64(f.size)
		if end > cursor {
			cursor = end
		}
	}

	if n.size == 0 {
		n.size = cursor
	}
	if n.size > cursor {
		tail := n.size - cursor
		append(&merged, Struct_Field{name = "PADDING", offset = u32(cursor), size = u32(tail), is_padding = true})
		n.pad_bytes += tail
	}

	delete(n.fields)
	n.fields = merged

	if n.cachelines == 0 && n.size > 0 {
		n.cachelines = u32((n.size + 63) / 64)
	}
}

// Parses `pahole` output into a Root -> Struct tree with field/padding detail.
// Returns ok=false when pahole is not installed on the system.
extract_structs :: proc(bin_path: string) -> (root: ^Node, ok: bool) {
	root = new(Node)
	root.kind = .Root
	root.name = "Structs (DWARF)"

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
