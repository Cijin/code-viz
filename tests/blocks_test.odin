package tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "../src/analyze"
import snap "../src/snapshot"

// A full snapshot from the captured samples: code, checks, opt-outs, blocks
// (from the fixture source) and types (from DWARF).
@(private)
full_snapshot :: proc(id: snap.Build_Id, objdump, dwarf, source: string, return_size: int) -> snap.Snapshot {
	s := safety_snapshot(id, objdump, source)
	s.types = parse_sample(dwarf)
	ast := analyze.analyze_source(s.source, context.temp_allocator)
	s.blocks = ast.blocks
	// DWARF return types (not in the objdump samples): Frame_Header.
	for sym, &pc in s.procs {
		if sym == "frame::parse_header" {
			pc.return_type = "frame::Frame_Header"
			pc.return_size = return_size
		}
	}
	return s
}

@(test)
mem_access_test :: proc(t: ^testing.T) {
	Case :: struct {
		text:  string,
		bytes: int,
		store: bool,
		stack: bool,
	}
	cases := []Case{
		{"ldrb\tw8, [x8]", 1, false, false},
		{"strb\tw9, [x8]", 1, true, false},
		{"str\tx9, [x8, #0x10]", 8, true, false},
		{"ldr\tw8, [x0]", 4, false, false},
		{"stp\tx29, x30, [sp, #0x70]", 16, true, true},
		{"ldur\tx0, [x29, #-0x8]", 8, false, true},
		{"mov\tqword ptr [rdi + 16], rax", 8, true, false},
		{"movzx\teax, byte ptr [rsi + rdx]", 1, false, false},
		{"mov\tdword ptr [rsp + 4], ecx", 4, true, true},
	}
	for c in cases {
		n, store, stack, ok := snap.mem_access(c.text)
		testing.expectf(t, ok && n == c.bytes && store == c.store && stack == c.stack,
			"%s -> %d %v %v %v", c.text, n, store, stack, ok)
	}
}

@(test)
block_ranges_test :: proc(t: ^testing.T) {
	src := make(map[string][]string, allocator = context.temp_allocator)
	src["frame.odin"] = strings.split_lines(SOURCE_V214, context.temp_allocator)
	ast := analyze.analyze_source(src, context.temp_allocator)
	found_type, stmts := false, 0
	for b in ast.blocks {
		if b.kind == .Type_Decl && b.owner == "frame::Frame_Header" {
			found_type = true
			testing.expect_value(t, b.first, 12)
			testing.expect_value(t, b.last, 17)
		}
		if b.kind == .Statement && b.owner == "frame::parse_header" do stmts += 1
	}
	testing.expect(t, found_type)
	testing.expect_value(t, stmts, 5) // kind, length, flags, stream_id, return
}

// SPEC §10 M5: the v213 -> v214 Blocks view matches Blocks.dc.html in
// structure: the changed type block first (+8 B), then parse_header's
// statements in source order, with the flags row gaining instructions, a
// check and a byte read; the return row writes through the result pointer;
// a Σ row with the build totals.
@(test)
blocks_structure_test :: proc(t: ^testing.T) {
	prev := full_snapshot(213, SAMPLE_OBJDUMP_V213, SAMPLE_DWARF_V213, SOURCE_V213, 16)
	curr := full_snapshot(214, SAMPLE_OBJDUMP_V214, SAMPLE_DWARF_V214, SOURCE_V214, 24)
	d := snap.diff(&prev, &curr, context.temp_allocator)
	b := d.blocks

	testing.expect(t, len(b.rows) >= 6)
	if len(b.rows) < 6 do return
	for r in b.rows {
		fmt.printf("  %v %s %d-%d exec %+d checks %+d mem %+d %s changed=%v\n",
			r.kind, snap.short_name(r.owner), r.first, r.last, r.exec_delta, r.check_delta, r.mem_delta, r.mem_label, r.changed)
	}

	// Type declaration block.
	ty := b.rows[0]
	testing.expect_value(t, ty.kind, snap.Block_Kind.Type_Decl)
	testing.expect_value(t, ty.owner, "frame::Frame_Header")
	testing.expect_value(t, ty.mem_delta, 8)
	testing.expect_value(t, len(ty.cells), 24)
	testing.expect(t, ty.changed)
	flags_line_changed := false
	for l in ty.lines do if l.line == 15 do flags_line_changed = l.changed
	testing.expect(t, flags_line_changed)

	// parse_header statements in source order.
	lines := make([dynamic]i32, context.temp_allocator)
	flags_row, return_row: snap.Block_Row
	for r in b.rows do if r.owner == "frame::parse_header" {
		append(&lines, r.first)
		if r.first == 27 do flags_row = r
		if r.first == 29 do return_row = r
	}
	testing.expect_value(t, len(lines), 5)
	for i in 1 ..< len(lines) do testing.expect(t, lines[i] > lines[i - 1])

	testing.expect(t, flags_row.changed)
	testing.expect(t, flags_row.exec_delta > 0)
	testing.expect_value(t, flags_row.check_delta, 1)
	testing.expect_value(t, flags_row.mem_delta, 1) // one byte read: buf[offset+5]
	testing.expect_value(t, len(flags_row.bars), 1)
	if len(flags_row.bars) == 1 {
		testing.expect(t, !flags_row.bars[0].store)
		testing.expect(t, flags_row.bars[0].new)
	}

	testing.expect(t, return_row.changed)
	testing.expect(t, return_row.exec_delta > 0)
	testing.expect_value(t, return_row.mem_label, "stack")
	written := 0
	for bar in return_row.bars do if bar.store do written += 1
	testing.expect_value(t, written, 24) // the whole 24 B result

	// Σ row and the auto-pinned block.
	testing.expect_value(t, b.sum_mem, 8)
	testing.expect(t, b.sum_checks >= 1)
	testing.expect(t, b.sum_exec > 0)
	testing.expect(t, b.selected >= 0 && b.rows[b.selected].changed)
}

// First build of a session: no previous snapshot. The build is compared with
// itself, so nothing is changed but the lenses still get data.
@(test)
first_build_has_current_state_test :: proc(t: ^testing.T) {
	curr := full_snapshot(214, SAMPLE_OBJDUMP_V214, SAMPLE_DWARF_V214, SOURCE_V214, 24)
	d := snap.diff(nil, &curr, context.temp_allocator)
	testing.expect_value(t, d.from, d.to)
	testing.expect(t, len(d.procs) > 0)
	testing.expect(t, len(d.types) > 0)
	for p in d.procs do testing.expect(t, !p.changed)
	// Memory opens on a type a reorder would shrink.
	_, has_fix := d.types[0].suggested.?
	testing.expect(t, has_fix)
	testing.expect_value(t, len(d.blocks.rows), 0)

	history := make([dynamic]snap.Build_Dots, context.temp_allocator)
	m := snap.build_glance(&d, history[:], context.temp_allocator)
	testing.expect(t, !m.exec.changed && !m.memory.changed && !m.safety.changed)
}
