package analyze

import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:strings"
import snap "../snapshot"

// SPEC §6.5 opt-outs and the implied checks of §6.4 ("removed" detection),
// from `core:odin/parser`. The parser has no type information, so:
// - every index and slice expression implies a check (maps and constant
//   indices into arrays have none, and show up as removed),
// - `[^]T` is reported where the type is written,
// - a raw pointer cast is any `cast(^T)` / `(^T)(x)` conversion.

Implied_Check :: struct {
	kind:  snap.Check_Kind,
	pos:   snap.Source_Pos,
	proc_: string, // package-qualified, like the symbol
}

Ast_Result :: struct {
	implied:  []Implied_Check,
	opt_outs: []snap.Opt_Out,
	blocks:   []snap.Block_Range,
}

@(private = "file")
Walk_State :: struct {
	rel:        string,
	pkg:        string,
	nodes:      [dynamic]^ast.Node,
	procs:      [dynamic]string,
	no_bounds:  int, // depth of #no_bounds_check regions
	proc_names: map[^ast.Proc_Lit]string,
	implied:    ^[dynamic]Implied_Check,
	opt_outs:   ^[dynamic]snap.Opt_Out,
}

@(private = "file")
pos_of :: proc(st: ^Walk_State, p: tokenizer.Pos) -> snap.Source_Pos {
	return {file = st.rel, line = i32(p.line)}
}

@(private = "file")
current_proc :: proc(st: ^Walk_State) -> string {
	return len(st.procs) > 0 ? st.procs[len(st.procs) - 1] : ""
}

@(private = "file")
visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	st := (^Walk_State)(v.data)
	if node == nil {
		// Leaving the most recent node.
		n := pop(&st.nodes)
		if _, is_proc := n.derived.(^ast.Proc_Lit); is_proc do pop(&st.procs)
		if .No_Bounds_Check in n.state_flags do st.no_bounds -= 1
		if pl, is_proc := n.derived.(^ast.Proc_Lit); is_proc && .No_Bounds_Check in pl.tags do st.no_bounds -= 1
		return nil
	}
	append(&st.nodes, node)

	if .No_Bounds_Check in node.state_flags {
		st.no_bounds += 1
		append(st.opt_outs, snap.Opt_Out{kind = .No_Bounds_Check, pos = pos_of(st, node.pos)})
	}

	#partial switch n in node.derived {
	case ^ast.Value_Decl:
		// Name the procs this declaration defines, for the proc stack.
		for value, i in n.values {
			if pl, ok := value.derived.(^ast.Proc_Lit); ok && i < len(n.names) {
				if id, iok := n.names[i].derived.(^ast.Ident); iok {
					st.proc_names[pl] = strings.concatenate({st.pkg, "::", id.name}, context.temp_allocator)
				}
			}
		}
	case ^ast.Proc_Lit:
		name := st.proc_names[n] or_else current_proc(st)
		append(&st.procs, name)
		if .No_Bounds_Check in n.tags {
			st.no_bounds += 1
			append(st.opt_outs, snap.Opt_Out{kind = .No_Bounds_Check, pos = pos_of(st, n.pos)})
		}
	case ^ast.Index_Expr:
		if st.no_bounds == 0 && current_proc(st) != "" {
			append(st.implied, Implied_Check{kind = .Index, pos = pos_of(st, n.open), proc_ = current_proc(st)})
		}
	case ^ast.Slice_Expr:
		if st.no_bounds == 0 && current_proc(st) != "" {
			append(st.implied, Implied_Check{kind = .Slice, pos = pos_of(st, n.open), proc_ = current_proc(st)})
		}
	case ^ast.Type_Cast:
		if n.tok.kind == .Transmute {
			append(st.opt_outs, snap.Opt_Out{kind = .Transmute, pos = pos_of(st, n.pos)})
		} else if _, is_ptr := n.type.derived.(^ast.Pointer_Type); is_ptr {
			append(st.opt_outs, snap.Opt_Out{kind = .Raw_Ptr_Cast, pos = pos_of(st, n.pos)})
		}
	case ^ast.Call_Expr:
		// `(^T)(x)` conversion syntax.
		if paren, ok := n.expr.derived.(^ast.Paren_Expr); ok {
			if _, is_ptr := paren.expr.derived.(^ast.Pointer_Type); is_ptr {
				append(st.opt_outs, snap.Opt_Out{kind = .Raw_Ptr_Cast, pos = pos_of(st, n.pos)})
			}
		}
	case ^ast.Multi_Pointer_Type:
		append(st.opt_outs, snap.Opt_Out{kind = .Multi_Pointer, pos = pos_of(st, n.pos)})
	}
	return v
}

// SPEC §7.4 block ranges: each top-level statement of a procedure body, and
// each struct declaration.
@(private = "file")
collect_blocks :: proc(file: ^ast.File, rel: string, blocks: ^[dynamic]snap.Block_Range) {
	for decl in file.decls {
		vd, ok := decl.derived.(^ast.Value_Decl)
		if !ok || len(vd.values) == 0 || len(vd.names) == 0 do continue
		id, iok := vd.names[0].derived.(^ast.Ident)
		if !iok do continue
		owner := strings.concatenate({file.pkg_name, "::", id.name}, context.temp_allocator)
		#partial switch v in vd.values[0].derived {
		case ^ast.Struct_Type:
			append(blocks, snap.Block_Range{kind = .Type_Decl, file = rel, first = i32(vd.pos.line), last = i32(vd.end.line), owner = owner})
		case ^ast.Proc_Lit:
			body, bok := v.body.derived.(^ast.Block_Stmt)
			if !bok do continue
			for stmt in body.stmts {
				append(blocks, snap.Block_Range{kind = .Statement, file = rel, first = i32(stmt.pos.line), last = i32(stmt.end.line), owner = owner})
			}
		}
	}
}

// Parses one file. Results go to `implied` / `opt_outs` / `blocks` with
// strings in the temp allocator; analyze_source copies them out.
parse_source_file :: proc(rel, src: string, implied: ^[dynamic]Implied_Check, opt_outs: ^[dynamic]snap.Opt_Out, blocks: ^[dynamic]snap.Block_Range = nil) -> bool {
	context.allocator = context.temp_allocator
	file := ast.File{src = src, fullpath = rel}
	p := parser.default_parser()
	p.err = proc(pos: tokenizer.Pos, msg: string, args: ..any) {}
	if !parser.parse_file(&p, &file) do return false

	st := Walk_State{rel = rel, pkg = file.pkg_name, implied = implied, opt_outs = opt_outs}
	st.proc_names = make(map[^ast.Proc_Lit]string)
	v := ast.Visitor{visit = visit, data = &st}
	for decl in file.decls do ast.walk(&v, decl)
	if blocks != nil do collect_blocks(&file, rel, blocks)
	return true
}

// All project files. `sources` maps project-relative paths to their lines.
analyze_source :: proc(sources: map[string][]string, allocator := context.allocator) -> Ast_Result {
	implied := make([dynamic]Implied_Check, context.temp_allocator)
	opt_outs := make([dynamic]snap.Opt_Out, context.temp_allocator)
	blocks := make([dynamic]snap.Block_Range, context.temp_allocator)
	for rel, lines in sources {
		parse_source_file(rel, strings.join(lines, "\n", context.temp_allocator), &implied, &opt_outs, &blocks)
	}
	res := Ast_Result{
		implied  = make([]Implied_Check, len(implied), allocator),
		opt_outs = make([]snap.Opt_Out, len(opt_outs), allocator),
		blocks   = make([]snap.Block_Range, len(blocks), allocator),
	}
	for b, i in blocks {
		res.blocks[i] = b
		res.blocks[i].file = strings.clone(b.file, allocator)
		res.blocks[i].owner = strings.clone(b.owner, allocator)
	}
	for c, i in implied {
		res.implied[i] = c
		res.implied[i].pos.file = strings.clone(c.pos.file, allocator)
		res.implied[i].proc_ = strings.clone(c.proc_, allocator)
	}
	for o, i in opt_outs {
		res.opt_outs[i] = o
		res.opt_outs[i].pos.file = strings.clone(o.pos.file, allocator)
	}
	return res
}

// SPEC §6.4: an implied check with no check call on its line in the
// emitted code is `removed: true`. Procs not in the binary are skipped:
// Odin emits no code for them (docs/VERIFIED.md §4).
removed_checks :: proc(implied: []Implied_Check, actual: []snap.Check_Site, emitted: map[string]bool, allocator := context.allocator) -> []snap.Check_Site {
	Key :: struct {
		file: string,
		line: i32,
	}
	has := make(map[Key]bool, allocator = context.temp_allocator)
	for c in actual do has[{c.pos.file, c.pos.line}] = true
	seen := make(map[Key]bool, allocator = context.temp_allocator)
	out := make([dynamic]snap.Check_Site, allocator)
	for ic in implied {
		k := Key{ic.pos.file, ic.pos.line}
		if ic.proc_ not_in emitted || has[k] || seen[k] do continue
		seen[k] = true
		append(&out, snap.Check_Site{kind = ic.kind, pos = ic.pos, proc_ = ic.proc_, removed = true})
	}
	return out[:]
}
