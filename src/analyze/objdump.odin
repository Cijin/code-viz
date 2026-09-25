package analyze

import "core:strconv"
import "core:strings"
import snap "../snapshot"

// SPEC §6.2: machine code by line from
// `llvm-objdump -d -l --no-show-raw-insn [--dsym=…] --disassemble-symbols=…`.
// A `; <path>:<line>` comment sets the position of the instructions after it.

Arch :: enum u8 {
	Arm64,
	X86_64,
}

HOST_ARCH :: Arch.Arm64 when ODIN_ARCH == .arm64 else Arch.X86_64

// SPEC §6.4 check handlers, matched on the name's suffix (after `::`).
CHECK_HANDLERS := []string{
	"bounds_check_error", "bounds_check_error_loc",
	"slice_expr_error_hi", "slice_expr_error_lo_hi", "slice_expr_error_hi_loc", "slice_expr_error_lo_hi_loc",
	"multi_pointer_slice_expr_error",
	"dynamic_array_expr_error", "dynamic_array_expr_error_loc",
	"matrix_bounds_check_error",
	"type_assertion_check", "type_assertion_check2",
	"bounds_trap",
	// Cold panic paths left when the checks above are inlined.
	"slice_handle_error", "handle_error-0",
}

// The callee named in a call's operands, e.g. `0x1000403 <_runtime::x>`.
call_target :: proc(operands: string) -> string {
	a := strings.index_byte(operands, '<')
	b := strings.last_index_byte(operands, '>')
	if a < 0 || b <= a do return ""
	t := operands[a + 1:b]
	if plus := strings.last_index_byte(t, '+'); plus > 0 do t = t[:plus]
	return strings.trim_prefix(t, "_")
}

// Which SPEC §6.4 check a call target is, if any.
check_kind_of :: proc(target: string) -> (snap.Check_Kind, bool) {
	if !strings.has_prefix(target, "runtime::") do return .Index, false
	name := target[len("runtime::"):]
	if dot := strings.index_byte(name, '.'); dot > 0 do name = name[:dot]
	switch {
	case strings.has_prefix(name, "bounds_check_error"):        return .Index, true
	case strings.has_prefix(name, "slice_expr_error"),
	     strings.has_prefix(name, "multi_pointer_slice_expr_error"),
	     strings.has_prefix(name, "slice_handle_error"):        return .Slice, true
	case strings.has_prefix(name, "dynamic_array_expr_error"):  return .Dynamic_Array, true
	case strings.has_prefix(name, "matrix_bounds_check_error"): return .Matrix, true
	case strings.has_prefix(name, "type_assertion_check"):      return .Type_Assert, true
	case strings.has_prefix(name, "bounds_trap"):               return .Trap, true
	}
	return .Index, false
}

// Handlers that never return: the block that calls them is cold.
@(private = "file")
is_noreturn_handler :: proc(target: string) -> bool {
	return strings.contains(target, "handle_error") || strings.has_suffix(target, "bounds_trap")
}

// SPEC §6.2 classification table.
classify :: proc(mnemonic, operands: string, arch: Arch) -> snap.Insn_Kind {
	m := strings.to_lower(mnemonic, context.temp_allocator)
	switch arch {
	case .Arm64:
		switch m {
		case "b", "cbz", "cbnz", "tbz", "tbnz", "br": return .Branch
		case "bl", "blr", "ret":                     return .Call
		case "ldp", "stp", "ldur", "stur":           return .Mem
		}
		if strings.has_prefix(m, "b.") do return .Branch
		if strings.has_prefix(m, "ldr") || strings.has_prefix(m, "str") do return .Mem
		return .Op
	case .X86_64:
		if m == "call" || m == "ret" do return .Call
		if strings.has_prefix(m, "j") do return .Branch
		if m != "lea" && strings.contains(operands, "[") do return .Mem
		return .Op
	}
	return .Op
}

Disasm_Proc :: struct {
	code:   snap.Proc_Code,
	calls:  []string,     // call targets in order, for inlining and check sites
	checks: []snap.Check_Site,
}

// Parses objdump text. `root` makes positions project-relative; lines in
// other files (inlined core code) keep the last project line, which is the
// call site. Mach-O's leading `_` is dropped from symbol names.
parse_objdump :: proc(text, root: string, arch: Arch, allocator := context.allocator) -> map[string]Disasm_Proc {
	out := make(map[string]Disasm_Proc, allocator = allocator)

	Building :: struct {
		symbol: string,
		insns:  [dynamic]snap.Insn,
		addrs:  [dynamic]u64,
		calls:  [dynamic]string,
		checks: [dynamic]snap.Check_Site,
	}
	cur: Maybe(Building)
	pos := snap.Source_Pos{}

	finish :: proc(out: ^map[string]Disasm_Proc, b: ^Building, arch: Arch, allocator := context.allocator) {
		mark_cold(b.insns[:], b.addrs[:])
		size := 0
		if n := len(b.addrs); n > 0 do size = int(b.addrs[n - 1] - b.addrs[0]) + (arch == .Arm64 ? 4 : 1)
		out[b.symbol] = Disasm_Proc{
			code   = snap.Proc_Code{symbol = b.symbol, size = size, insns = b.insns[:]},
			calls  = b.calls[:],
			checks = b.checks[:],
		}
	}

	rest := text
	for line in strings.split_lines_iterator(&rest) {
		// Symbol header: `0000000100015130 <_frame::parse_header>:`
		if lt := strings.index_byte(line, '<'); lt >= 0 && strings.has_suffix(line, ">:") && !strings.contains(line, "\t") {
			if b, ok := &cur.?; ok do finish(&out, b, arch, allocator)
			name := strings.trim_prefix(line[lt + 1:len(line) - 2], "_")
			cur = Building{
				symbol = strings.clone(name, allocator),
				insns  = make([dynamic]snap.Insn, allocator),
				addrs  = make([dynamic]u64, context.temp_allocator),
				calls  = make([dynamic]string, allocator),
				checks = make([dynamic]snap.Check_Site, allocator),
			}
			pos = {}
			continue
		}
		b, ok := &cur.?
		if !ok do continue

		if strings.has_prefix(line, "; ") {
			// `; /abs/path.odin:27` (skip `; frame::parse_header():`)
			c := line[2:]
			colon := strings.last_index_byte(c, ':')
			if colon > 0 && strings.has_prefix(c, "/") {
				if ln, lok := strconv.parse_int(c[colon + 1:]); lok {
					if rel := project_relative(c[:colon], root); rel != "" {
						pos = {file = strings.clone(rel, allocator), line = i32(ln)}
					}
				}
			}
			continue
		}

		// Instruction: `100015130:     \tsub\tsp, sp, #0x80` (addresses on).
		colon := strings.index_byte(line, ':')
		if colon <= 0 do continue
		addr, aok := strconv.parse_u64(strings.trim_space(line[:colon]), 16)
		if !aok do continue
		body := strings.trim_space(line[colon + 1:])
		if body == "" do continue
		if sc := strings.index(body, " ;"); sc >= 0 do body = strings.trim_space(body[:sc])
		mnemonic, operands := body, ""
		if sep := strings.index_any(body, " \t"); sep >= 0 {
			mnemonic, operands = body[:sep], strings.trim_space(body[sep:])
		}

		kind := classify(mnemonic, operands, arch)
		append(&b.insns, snap.Insn{kind = kind, pos = pos, text = strings.clone(body, allocator)})
		append(&b.addrs, addr)
		if kind == .Call {
			if target := call_target(operands); target != "" {
				append(&b.calls, strings.clone(target, allocator))
				if ck, is_check := check_kind_of(target); is_check {
					append(&b.checks, snap.Check_Site{kind = ck, pos = pos, proc_ = b.symbol})
				}
			}
		}
	}
	if b, ok := &cur.?; ok do finish(&out, b, arch, allocator)
	return out
}

// SPEC §6.2 cold code: a basic block that ends in a call to a check handler
// that never returns. Blocks start at branch targets and after branches.
@(private = "file")
mark_cold :: proc(insns: []snap.Insn, addrs: []u64) {
	targets := make(map[u64]bool, context.temp_allocator)
	for insn in insns do if insn.kind == .Branch {
		if t := strings.index(insn.text, "0x"); t >= 0 {
			hex := insn.text[t + 2:]
			end := 0
			for end < len(hex) && strings.contains_rune("0123456789abcdef", rune(hex[end])) do end += 1
			if v, ok := strconv.parse_u64(hex[:end], 16); ok do targets[v] = true
		}
	}
	for insn, i in insns {
		if insn.kind != .Call do continue
		ops := insn.text
		if sep := strings.index_any(ops, " \t"); sep >= 0 do ops = ops[sep:]
		if !is_noreturn_handler(call_target(ops)) do continue
		// Walk back to the start of this block.
		j := i
		for j > 0 && !(addrs[j] in targets) && insns[j - 1].kind != .Branch && insns[j - 1].kind != .Call do j -= 1
		for k in j ..= i do insns[k].cold = true
	}
}

// Defined project procs from `llvm-nm --defined-only` (text symbols whose
// package is in `packages`). Mach-O's leading `_` is dropped.
parse_nm_procs :: proc(text: string, packages: []string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 3 || (f[1] != "T" && f[1] != "t") do continue
		name := strings.trim_prefix(f[2], "_")
		for pkg in packages {
			if strings.has_prefix(name, pkg) && strings.has_prefix(name[len(pkg):], "::") {
				append(&out, strings.clone(name, allocator))
				break
			}
		}
	}
	return out[:]
}

// Disassembles the project's procs from a green build.
analyze_code :: proc(artifact, root: string, packages: []string, allocator := context.allocator) -> (procs: map[string]Disasm_Proc, ok: bool) {
	nm := find_tool("llvm-nm")
	objdump := find_tool("llvm-objdump")
	if nm == "" || objdump == "" do return
	nm_out := run_tool({nm, "--defined-only", artifact}, context.temp_allocator) or_return
	syms := parse_nm_procs(nm_out, packages, context.temp_allocator)
	if len(syms) == 0 do return make(map[string]Disasm_Proc, allocator = allocator), true

	// `--disassemble-symbols` cannot match names with `[...]` (file-private
	// procs, docs/VERIFIED.md §4); those are skipped for now.
	list := strings.builder_make(context.temp_allocator)
	prefix := ODIN_OS == .Darwin ? "_" : ""
	n := 0
	for s in syms {
		if strings.contains(s, "[") do continue
		if n > 0 do strings.write_byte(&list, ',')
		strings.write_string(&list, prefix)
		strings.write_string(&list, s)
		n += 1
	}
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, objdump, "-d", "-l", "--no-show-raw-insn")
	if HOST_ARCH == .X86_64 do append(&argv, "-M", "intel")
	if dw := dwarf_path(artifact, context.temp_allocator); dw != artifact do append(&argv, strings.concatenate({"--dsym=", dw}, context.temp_allocator))
	append(&argv, strings.concatenate({"--disassemble-symbols=", strings.to_string(list)}, context.temp_allocator), artifact)
	text := run_tool(argv[:], context.temp_allocator) or_return
	return parse_objdump(text, root, HOST_ARCH, allocator), true
}
