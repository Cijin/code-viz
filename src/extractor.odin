package viz

import "core:c/libc"
import "core:fmt"
import "core:os"
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
// binary path the platform's struct extraction reads DWARF from.
compile_target :: proc(target_dir: string) -> (bin_path: string, ok: bool) {
	bin_path = "/tmp/viz_target"

	extra := ""
	if !target_has_main(target_dir) {
		// A single module yields one object file instead of one per package.
		bin_path = "/tmp/viz_target.o"
		extra = " -build-mode:obj -use-single-module"
	}

	// Clear previous outputs so a failed build can't pass off a stale binary.
	run_cmd(fmt.tprintf("rm -rf %s %s.dSYM", bin_path, bin_path))

	cmd := fmt.tprintf("odin build %s -debug -out:%s%s 2>&1", target_dir, bin_path, extra)
	out := run_cmd(cmd)

	if os.exists(bin_path) {
		return bin_path, true
	}

	fmt.eprintln("odin build failed:")
	fmt.eprintln(out)
	return "", false
}

new_struct_root :: proc() -> ^Node {
	root := new(Node)
	root.kind = .Root
	root.name = "All structs"
	return root
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

Own_Sources :: struct {
	cwd:      string, // decl paths are shown relative to this
	packages: ^map[string]bool,
	decls:    ^map[string]Source_Decl,
}

// Walks target_dir for .odin files, recording the packages they declare (to
// separate the user's code from core/base/vendor) and each top-level
// declaration's file and line (to place tiles in the UI).
scan_own_sources :: proc(target_dir: string, packages: ^map[string]bool, decls: ^map[string]Source_Decl) {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	src := Own_Sources{cwd = cwd, packages = packages, decls = decls}
	scan_dir(&src, target_dir)
}

@(private = "file")
scan_dir :: proc(src: ^Own_Sources, dir: string) {
	fh, err := os.open(dir)
	if err != nil do return
	defer os.close(fh)

	entries, rerr := os.read_dir(fh, -1, context.temp_allocator)
	if rerr != nil do return

	for e in entries {
		if e.type == .Directory {
			if !strings.has_prefix(e.name, ".") do scan_dir(src, e.fullpath)
			continue
		}
		if strings.has_suffix(e.name, ".odin") && file_suffix_matches_os(e.name) do scan_file(src, e.fullpath)
	}
}

@(private = "file")
scan_file :: proc(src: ^Own_Sources, path: string) {
	data, rd_err := os.read_entire_file(path, context.temp_allocator)
	if rd_err != nil do return

	// read_dir yields absolute paths; show them relative to where viz runs.
	rel := path
	if src.cwd != "" && strings.has_prefix(path, src.cwd) {
		rel = strings.trim_prefix(path[len(src.cwd):], "/")
	}
	pkg := ""

	for line, i in strings.split_lines(string(data), context.temp_allocator) {
		trimmed := strings.trim_space(line)

		if pkg == "" {
			// Files the compiler excludes for this OS would shadow the real
			// declarations (e.g. both platform backends define extract_structs).
			if strings.has_prefix(trimmed, "#+build ") && !build_tag_matches(trimmed[len("#+build "):]) do return
			if strings.has_prefix(trimmed, "package ") {
				fields := strings.fields(trimmed, context.temp_allocator)
				if len(fields) >= 2 {
					pkg = fields[1]
					if pkg not_in src.packages^ do src.packages[strings.clone(pkg)] = true
				}
			}
			continue
		}

		// Top-level declarations start in column 0: `Name :: ...` or `name: T`.
		name := top_level_decl_name(line)
		if name == "" do continue
		key := fmt.aprintf("%s::%s", pkg, name)
		if key in src.decls^ {
			delete(key)
			continue
		}
		src.decls[key] = Source_Decl{
			file = strings.clone(rel),
			line = i + 1,
		}
	}
}

KNOWN_OS_TAGS :: []string{"windows", "darwin", "linux", "essence", "freebsd", "openbsd", "netbsd", "haiku", "wasi", "js", "freestanding", "orca"}

// Mirrors Odin's `name_<os>.odin` / `name_<os>_<arch>.odin` file rule.
@(private = "file")
file_suffix_matches_os :: proc(name: string) -> bool {
	stem := strings.trim_suffix(name, ".odin")
	parts := strings.split(stem, "_", context.temp_allocator)
	if len(parts) < 2 do return true
	for os_tag in KNOWN_OS_TAGS {
		last := parts[len(parts) - 1]
		if last == os_tag do return os_tag == ODIN_OS_STRING
		if len(parts) >= 3 && parts[len(parts) - 2] == os_tag {
			return os_tag == ODIN_OS_STRING && last == ODIN_ARCH_STRING
		}
	}
	return true
}

// Evaluates one `#+build` line: comma-separated alternatives, each a
// space-separated conjunction of `os`/`arch` tags, optionally negated with `!`.
@(private = "file")
build_tag_matches :: proc(expr: string) -> bool {
	for alt in strings.split(expr, ",", context.temp_allocator) {
		all := true
		for tok in strings.fields(alt, context.temp_allocator) {
			neg := strings.has_prefix(tok, "!")
			tag := strings.trim_prefix(tok, "!")
			if (tag == ODIN_OS_STRING || tag == ODIN_ARCH_STRING) == neg {
				all = false
				break
			}
		}
		if all do return true
	}
	return false
}

@(private = "file")
top_level_decl_name :: proc(line: string) -> string {
	if line == "" || line[0] == ' ' || line[0] == '\t' do return ""
	n := 0
	for n < len(line) {
		c := line[n]
		if !(c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (n > 0 && c >= '0' && c <= '9')) do break
		n += 1
	}
	if n == 0 do return ""
	rest := strings.trim_left_space(line[n:])
	if !strings.has_prefix(rest, ":") do return ""
	switch line[:n] {
	case "package", "import", "foreign":
		return ""
	}
	return line[:n]
}

// Declaration lookup key for a struct: proc-local types (`outer::T::$1`)
// are attributed to their enclosing top-level decl.
decl_key :: proc(pkg, name: string) -> string {
	base := name
	if idx := strings.index_any(base, ".-:"); idx > 0 do base = base[:idx]
	return fmt.tprintf("%s::%s", pkg, base)
}

// Attaches source info to `parent`'s `pkg::Name` struct children and
// regroups them under one File node per source file.
group_by_file :: proc(parent: ^Node, decls: map[string]Source_Decl) {
	files := make(map[string]^Node, context.temp_allocator)
	grouped: [dynamic]^Node

	for child in parent.children {
		child_pkg := node_package(child.name)
		child_name := child.name[len(child_pkg) + 2:] if len(child.name) > len(child_pkg) + 2 else child.name
		// Inside the user's own view the package prefix is noise, as is the
		// compiler's `::$1` suffix on proc-local types.
		child.name = child_name
		if idx := strings.index(child_name, "::$"); idx > 0 do child.name = child_name[:idx]

		file_name := "(compiler-generated)"
		if d, found := decls[decl_key(child_pkg, child_name)]; found {
			child.decl = d
			file_name = d.file
		}

		file_node, has := files[file_name]
		if !has {
			file_node = new(Node)
			file_node.kind = .File
			file_node.own = true
			file_node.name = strings.clone(file_name)
			file_node.decl.file = file_node.name
			files[file_name] = file_node
			append(&grouped, file_node)
		}
		append(&file_node.children, child)
		file_node.size += child.size
	}

	delete(parent.children)
	parent.children = grouped
}

node_package :: proc(name: string) -> string {
	if idx := strings.index(name, "::"); idx >= 0 do return name[:idx]
	return name
}

struct_count :: proc(n: ^Node) -> int {
	if n.kind == .Struct do return 1
	count := 0
	for child in n.children do count += struct_count(child)
	return count
}

mark_own :: proc(n: ^Node) {
	n.own = true
	for child in n.children do mark_own(child)
}

// Returns a root holding only the `pkg::Type` children of `full` whose
// package is in `pkgs`, flagging them as the user's own code.
filter_own :: proc(full: ^Node, pkgs: map[string]bool) -> ^Node {
	root := new(Node)
	root.kind = .Root
	root.name = "Your structs"
	for child in full.children {
		if node_package(child.name) not_in pkgs do continue
		mark_own(child)
		append(&root.children, child)
		root.size += child.size
	}
	return root
}
