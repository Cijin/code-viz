package tests

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "../src/analyze"
import snap "../src/snapshot"

SAMPLE_OBJDUMP_V213 :: #load("samples/objdump_frame_v213.txt", string)
SAMPLE_OBJDUMP_V214 :: #load("samples/objdump_frame_v214.txt", string)
SOURCE_V213 :: #load("../fixtures/frame_v213/frame.odin", string)
SOURCE_V214 :: #load("../fixtures/frame_v214/frame.odin", string)

// A snapshot from captured objdump output and the fixture's source.
@(private)
exec_snapshot :: proc(id: snap.Build_Id, objdump, source: string) -> snap.Snapshot {
	s := snap.Snapshot{id = id}
	s.procs = make(map[string]snap.Proc_Code, allocator = context.temp_allocator)
	for sym, dp in analyze.parse_objdump(objdump, "/project", .Arm64, context.temp_allocator) do s.procs[sym] = dp.code
	s.source = make(map[string][]string, allocator = context.temp_allocator)
	s.source["frame.odin"] = strings.split_lines(source, context.temp_allocator)
	return s
}

@(test)
classify_test :: proc(t: ^testing.T) {
	testing.expect_value(t, analyze.classify("ldrb", "w8, [x8]", .Arm64), snap.Insn_Kind.Mem)
	testing.expect_value(t, analyze.classify("stp", "x29, x30, [sp, #0x70]", .Arm64), snap.Insn_Kind.Mem)
	testing.expect_value(t, analyze.classify("b.hs", "0x1000", .Arm64), snap.Insn_Kind.Branch)
	testing.expect_value(t, analyze.classify("cbz", "x1, 0x1000", .Arm64), snap.Insn_Kind.Branch)
	testing.expect_value(t, analyze.classify("bl", "0x1000 <_x>", .Arm64), snap.Insn_Kind.Call)
	testing.expect_value(t, analyze.classify("ret", "", .Arm64), snap.Insn_Kind.Call)
	testing.expect_value(t, analyze.classify("add", "x0, x0, x8", .Arm64), snap.Insn_Kind.Op)
	testing.expect_value(t, analyze.classify("mov", "rax, qword ptr [rdi + 8]", .X86_64), snap.Insn_Kind.Mem)
	testing.expect_value(t, analyze.classify("lea", "rax, [rip + 16]", .X86_64), snap.Insn_Kind.Op)
	testing.expect_value(t, analyze.classify("jne", "0x40", .X86_64), snap.Insn_Kind.Branch)
	testing.expect_value(t, analyze.classify("call", "0x40", .X86_64), snap.Insn_Kind.Call)
}

@(test)
objdump_parse_test :: proc(t: ^testing.T) {
	procs := analyze.parse_objdump(SAMPLE_OBJDUMP_V214, "/project", .Arm64, context.temp_allocator)
	testing.expect(t, "frame::parse_header" in procs)
	testing.expect(t, "frame::read_frame" in procs)
	testing.expect(t, "frame::decode_10k_frames" in procs)
	ph := procs["frame::parse_header"]
	testing.expect(t, len(ph.code.insns) > 0)
	testing.expect_value(t, ph.code.insns[0].pos.file, "frame.odin")
	testing.expect_value(t, ph.code.insns[0].pos.line, 24)
	testing.expect_value(t, ph.code.size, len(ph.code.insns) * 4)
	// parse_header's check calls at -o:minimal (docs/VERIFIED.md).
	lines := make([dynamic]i32, context.temp_allocator)
	for c in ph.checks do append(&lines, c.pos.line)
	testing.expect(t, slice.equal(lines[:], []i32{25, 26, 27, 28}))
}

@(test)
line_mapping_test :: proc(t: ^testing.T) {
	old := strings.split_lines(SOURCE_V213, context.temp_allocator)
	new := strings.split_lines(SOURCE_V214, context.temp_allocator)
	pairs := snap.pair_lines(old, new, context.temp_allocator)
	testing.expect_value(t, pairs[24], 22) // parse_header :: proc
	testing.expect_value(t, pairs[25], 23) // kind := buf[offset]
	testing.expect_value(t, pairs[27], 0)  // flags: new line
	testing.expect_value(t, pairs[28], 25) // stream_id: edited, paired by similarity
	testing.expect_value(t, pairs[29], 26) // return: edited, paired by similarity
}

// SPEC §10 M3: new instructions map to the `flags` and `return` lines.
@(test)
new_insns_on_flags_and_return_test :: proc(t: ^testing.T) {
	prev := exec_snapshot(213, SAMPLE_OBJDUMP_V213, SOURCE_V213)
	curr := exec_snapshot(214, SAMPLE_OBJDUMP_V214, SOURCE_V214)
	procs := snap.diff_procs(&prev, &curr, context.temp_allocator)

	ph: snap.Proc_Delta
	for p in procs do if p.symbol == "frame::parse_header" do ph = p
	testing.expect(t, ph.new_count > ph.old_count)

	// The two lines with the most new instructions are `flags` (27) and
	// `return` (29), and they hold most of the growth. At -o:minimal a few
	// other lines gain spills, e.g. line 24 stores the hidden result pointer
	// the 24 B return now needs (docs/VERIFIED.md).
	Line_New :: struct {
		line: i32,
		new:  int,
	}
	counts := make([dynamic]Line_New, context.temp_allocator)
	total_new := 0
	for r in ph.rows {
		n := 0
		for gl in r.now do if gl.mark == .New do n += 1
		total_new += n
		if n > 0 do append(&counts, Line_New{r.line, n})
		fmt.printf("  line %d (was %d) %d -> %d  %s\n", r.line, r.old_line, len(r.old), len(r.now), strings.trim_space(r.code))
	}
	// Old-side marks: every instruction the new build no longer has is a
	// gain, so removed = old - matched and matched = new - new marks.
	for r in ph.rows {
		gains, news := 0, 0
		for gl in r.old do if gl.mark == .Gain do gains += 1
		for gl in r.now do if gl.mark == .New do news += 1
		testing.expect_value(t, gains, len(r.old) - (len(r.now) - news))
	}

	slice.sort_by(counts[:], proc(a, b: Line_New) -> bool {return a.new > b.new})
	testing.expect(t, len(counts) >= 2)
	if len(counts) >= 2 {
		top := []i32{counts[0].line, counts[1].line}
		testing.expect(t, slice.contains(top, 27)) // flags := buf[offset+5]
		testing.expect(t, slice.contains(top, 29)) // return {kind, length, flags, stream_id}
		testing.expectf(t, f32(counts[0].new + counts[1].new) >= 0.7 * f32(total_new),
			"flags+return hold %d of %d new instructions", counts[0].new + counts[1].new, total_new)
	}
}
