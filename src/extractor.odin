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
// binary path used by the platform's symbol/struct extraction passes.
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

Symbol_Tree :: struct {
	root:    ^Node,
	pkg_map: map[string]^Node,
}

symbol_tree_make :: proc() -> Symbol_Tree {
	root := new(Node)
	root.kind = .Root
	root.name = "Binary Footprint"
	return Symbol_Tree{root = root, pkg_map = make(map[string]^Node, context.temp_allocator)}
}

// Files a symbol under its package, splitting `pkg::name` on the first `::`.
symbol_tree_add :: proc(t: ^Symbol_Tree, full_name: string, size: u64, kind: Node_Kind) {
	pkg_name := "other"
	sym_name := full_name
	if idx := strings.index(full_name, "::"); idx >= 0 {
		pkg_name = full_name[:idx]
		sym_name = full_name[idx + 2:]
	}
	// File-private procs are mangled `pkg::[file.odin]::name`.
	if strings.has_prefix(sym_name, "[") {
		if idx := strings.index(sym_name, "]::"); idx >= 0 do sym_name = sym_name[idx + 3:]
	}

	pkg_node, found := t.pkg_map[pkg_name]
	if !found {
		pkg_node = new(Node)
		pkg_node.kind = .Package
		pkg_node.name = strings.clone(pkg_name)
		append(&t.root.children, pkg_node)
		t.pkg_map[pkg_name] = pkg_node
	}

	sym_node := new(Node)
	sym_node.kind = kind
	sym_node.name = strings.clone(sym_name)
	sym_node.size = size
	append(&pkg_node.children, sym_node)
	pkg_node.size += size
	t.root.size += size
}

new_struct_root :: proc() -> ^Node {
	root := new(Node)
	root.kind = .Root
	root.name = "Structs (DWARF)"
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

// Collects the package names declared by .odin files under target_dir, so the
// views can separate the user's code from core/base/vendor packages.
collect_own_packages :: proc(target_dir: string, pkgs: ^map[string]bool) {
	fh, err := os.open(target_dir)
	if err != nil do return
	defer os.close(fh)

	entries, rerr := os.read_dir(fh, -1, context.temp_allocator)
	if rerr != nil do return

	for e in entries {
		if e.type == .Directory {
			if !strings.has_prefix(e.name, ".") do collect_own_packages(e.fullpath, pkgs)
			continue
		}
		if !strings.has_suffix(e.name, ".odin") do continue
		data, rd_err := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rd_err != nil do continue

		for line in strings.split_lines(string(data), context.temp_allocator) {
			trimmed := strings.trim_space(line)
			if !strings.has_prefix(trimmed, "package ") do continue
			fields := strings.fields(trimmed, context.temp_allocator)
			if len(fields) >= 2 && fields[1] not_in pkgs^ {
				pkgs[strings.clone(fields[1])] = true
			}
			break
		}
	}
}

node_package :: proc(name: string) -> string {
	if idx := strings.index(name, "::"); idx >= 0 do return name[:idx]
	return name
}

mark_own :: proc(n: ^Node) {
	n.own = true
	for child in n.children do mark_own(child)
}

// Returns a root holding only the children of `full` that belong to `pkgs`,
// flagging them (and their subtrees) as the user's own code.
// Symbol children are package nodes; struct children are named `pkg::Type`.
filter_own :: proc(full: ^Node, pkgs: map[string]bool) -> ^Node {
	root := new(Node)
	root.kind = .Root
	root.name = full.name
	for child in full.children {
		if node_package(child.name) not_in pkgs do continue
		mark_own(child)
		append(&root.children, child)
		root.size += child.size
	}
	return root
}
